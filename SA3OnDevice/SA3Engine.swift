import Foundation

/// Swift wrapper over the libsa3 C ABI (vendor/include/libsa3.h).
///
/// Everything here blocks, so callers run it off the main actor. libsa3 is not reentrant: one
/// generate or train at a time per context, which `queue` enforces.
/// One trained adapter. `variant` is the base it targets — see SA3Engine.adapters for why it is
/// stored rather than read back from the gguf.
struct AdapterEntry: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Filename only, never an absolute path: the app's data-container UUID is not stable across
    /// reinstalls, so a stored absolute path goes stale and the entry looks deleted.
    var file: String
    /// For a DiT adapter, the variant it was trained against. For an autoencoder adapter, the SAME
    /// family ("same-s" / "same-l") — those are shared across variants, so keying on variant would
    /// wrongly hide a same-s decoder adapter from small-sfx.
    var variant: String
    var encoding: String
    var rank: Int
    var steps: Int
    var created: Date
    /// "dit" | "decoder" | "encoder". libsa3 routes by the gguf's own lora.target, so this is only
    /// for filtering and for letting the UI offer a DiT and an autoencoder adapter side by side.
    var target: String = "dit"

    /// Entries written before `target` existed are DiT adapters; decode them as such rather than
    /// dropping the registry on the floor.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Older registries stored an absolute path; keep only its filename.
        if let f = try c.decodeIfPresent(String.self, forKey: .file) {
            file = f
        } else {
            file = ((try c.decode(String.self, forKey: .path)) as NSString).lastPathComponent
        }
        variant = try c.decode(String.self, forKey: .variant)
        encoding = try c.decode(String.self, forKey: .encoding)
        rank = try c.decode(Int.self, forKey: .rank)
        steps = try c.decode(Int.self, forKey: .steps)
        created = try c.decode(Date.self, forKey: .created)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? "dit"
    }

    init(id: String, name: String, file: String, variant: String, encoding: String,
         rank: Int, steps: Int, created: Date, target: String = "dit") {
        self.id = id; self.name = name; self.file = file; self.variant = variant
        self.encoding = encoding; self.rank = rank; self.steps = steps
        self.created = created; self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case id, name, file, path, variant, encoding, rank, steps, created, target
    }

    /// Rebuilt from the live container each time rather than persisted.
    var url: URL { SA3Engine.adaptersDir.appendingPathComponent(file) }
    var path: String { url.path }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id);         try c.encode(name, forKey: .name)
        try c.encode(file, forKey: .file);     try c.encode(variant, forKey: .variant)
        try c.encode(encoding, forKey: .encoding); try c.encode(rank, forKey: .rank)
        try c.encode(steps, forKey: .steps);   try c.encode(created, forKey: .created)
        try c.encode(target, forKey: .target)
    }
}

/// safetensors is [u64 LE header length][JSON header][tensor data]. `save_lora_safetensors` puts the
/// adapter's whole config in `__metadata__` under a single `lora_config` key, as a JSON *string* —
/// so the useful fields (target, base_model, rank) are one level deeper than a flat lookup finds.
/// Values are authoritative where a filename is only a convention, and base_model is what tells a
/// same-l adapter apart from a same-s one when neither name says so.
func sa3ReadAdapterConfig(_ url: URL) -> [String: Any] {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
    defer { try? fh.close() }
    guard let lenData = try? fh.read(upToCount: 8), lenData.count == 8 else { return [:] }
    let n = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    guard n > 0, n < 8_000_000, let hdr = try? fh.read(upToCount: Int(n)) else { return [:] }
    guard let obj = try? JSONSerialization.jsonObject(with: hdr) as? [String: Any],
          let meta = obj["__metadata__"] as? [String: Any] else { return [:] }
    if let raw = meta["lora_config"] as? String, let d = raw.data(using: .utf8),
       let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        return cfg
    }
    return meta   // older/flat exports
}

/// Which SAME a variant carries. medium is SAME-L; both small variants share SAME-S, and a decoder
/// adapter for one is valid for the other.
func sa3AutoencoderFamily(for variant: String) -> String {
    variant == "medium" ? "same-l" : "same-s"
}

@MainActor
final class SA3Engine: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case working(String)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var log: [String] = []
    @Published var progress: Double = 0
    @Published var lastStep: TrainStep?

    /// Adapters this device has trained. The gguf records `lora.adapter_type` but NOT which base
    /// it targets, so the variant cannot be recovered from the file — we record it at train time
    /// or we lose it. That is the whole reason this registry exists rather than a directory scan.
    @Published var adapters: [AdapterEntry] = []

    /// The variant currently loaded, as opposed to the one selected in the UI. An adapter is only
    /// applicable to the base it was trained against, so the picker filters on this.
    @Published private(set) var loadedVariant: String?

    struct TrainStep: Equatable {
        var step: Int
        var maxSteps: Int
        var loss: Float
        var gradNorm: Double
        var seconds: Double
    }

    /// Latent frames per second. Both SAME-S and SAME-L carry patch_size=256 and output_seg=16,
    /// so one latent frame is 4096 samples at 44.1 kHz for every variant — one constant is safe.
    static let framesPerSecond = 44100.0 / 4096.0   // ~10.767

    /// Where the gguf set lives. Models are too big to ship in the bundle for an experiment, so
    /// they are side-loaded into the app's Documents directory (see README).
    static var modelsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
    }

    /// nonisolated: it is a pure path lookup, and AdapterEntry (a plain struct) resolves against it.
    nonisolated static var adaptersDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("adapters")
    }

    static var registryURL: URL { adaptersDir.appendingPathComponent("registry.json") }

    static var datasetsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("datasets")
    }

    /// The simulator's Metal reports MTLGPUFamilyApple2 and traps on ggml's kernels, so force CPU
    /// there. On a real device Metal is the whole point, so leave the default (GPU if available).
    static var device: String {
        #if targetEnvironment(simulator)
        return "cpu"
        #else
        return ""
        #endif
    }

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "sa3.engine", qos: .userInitiated)
    private var activeBox: CallbackBox?

    /// Metal residency sets keep buffers wired — non-evictable — for 3 minutes after last use, so
    /// the OS cannot collect them. The autoencoder encode builds a fresh allocator per chunk, so on
    /// a full-corpus pre-encode wired buffers accumulate faster than they retire and the GPU
    /// eventually cannot allocate: it resets, and the in-flight command buffer comes back as
    /// kIOGPUCommandBufferCallbackErrorInnocentVictim. Invisible on a desktop, fatal on 4 GB.
    ///
    /// 5 s is short enough that pre-encode keeps up and long enough to avoid rewiring on every
    /// graph during inference. Set GGML_METAL_RESIDENCY_KEEP_ALIVE_S in the environment to override
    /// — the 0 in setenv means an existing value wins, so a devicectl launch can still steer it.
    static let residencyKeepAliveSeconds = "5"

    init() {
        setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", Self.residencyKeepAliveSeconds, 0)
        loadRegistry()
        recoverOrphanedAdapters()
        importPendingExports()
        append("metal residency keep-alive: \(getenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S").map { String(cString: $0) } ?? "default")s")
    }

    // MARK: - storage

    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Bytes under Documents, by top-level bucket. `.Trash` is where the Files app parks anything
    /// deleted from the container: still on disk, and still counted against the device, until it is
    /// emptied. Training runs are the other growing bucket — each keeps a trainer-state checkpoint
    /// alongside the adapter, and nothing prunes them.
    func storageReport() -> [(String, Int64)] {
        let fm = FileManager.default
        let root = Self.documentsDir
        var out: [String: Int64] = [:]
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                    options: []) else { return [] }
        for entry in top {
            let name = entry.lastPathComponent
            let key = name.hasPrefix("train-run") ? "train-runs"
                    : (name.hasPrefix("out-") ? "wavs" : name)
            out[key, default: 0] += Self.sizeOf(entry)
        }
        return out.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let vals = try? url.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
            let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                  options: [])          // no skipsHidden: .Trash must be counted
            while let f = e?.nextObject() as? URL {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        } else {
            total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Empties the Files-app trash. Everything in it was already deleted by the user, so this only
    /// makes that deletion take effect.
    func emptyTrash() {
        let fm = FileManager.default
        let trash = Self.documentsDir.appendingPathComponent(".Trash")
        guard let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil,
                                                      options: []) else {
            append("nothing in .Trash"); return
        }
        var freed: Int64 = 0
        for item in items {
            let sz = Self.sizeOf(item)
            do { try fm.removeItem(at: item); freed += sz }
            catch { append("could not remove \(item.lastPathComponent)") }
        }
        append(String(format: "emptied .Trash, freed %.2f GB", Double(freed) / 1e9))
    }

    /// Removes finished run directories whose adapter is already in the registry, so the copy in
    /// adapters/ is the surviving one. Keeps any run we have not registered — that is the only
    /// place an unregistered adapter still exists — and keeps the newest run regardless, since its
    /// trainer-state is what a --resume would need.
    func pruneTrainRuns() {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: Self.documentsDir,
                                                    includingPropertiesForKeys: nil) else { return }
        let runs = top.filter { $0.lastPathComponent.hasPrefix("train-run") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard runs.count > 1 else { append("no prunable runs"); return }
        var freed: Int64 = 0, n = 0
        for run in runs.dropFirst() {                    // keep the newest
            let final = run.appendingPathComponent("adapter-final.gguf")
            let registered = adapters.contains { $0.steps > 0 } && fm.fileExists(atPath: final.path)
            let empty = !fm.fileExists(atPath: final.path)
            guard registered || empty else { continue }
            let sz = Self.sizeOf(run)
            if (try? fm.removeItem(at: run)) != nil { freed += sz; n += 1 }
        }
        append(String(format: "pruned %d run dir(s), freed %.2f GB", n, Double(freed) / 1e9))
    }

    // MARK: - adapter registry

    /// Reads the registry, dropping entries whose gguf has since been deleted (via the Files app,
    /// say) so the picker never offers something that will fail to load.
    func loadRegistry() {
        guard let data = try? Data(contentsOf: Self.registryURL),
              let decoded = try? JSONDecoder().decode([AdapterEntry].self, from: data) else {
            adapters = []
            return
        }
        adapters = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if adapters.count != decoded.count { saveRegistry() }
    }

    private func saveRegistry() {
        try? FileManager.default.createDirectory(at: Self.adaptersDir,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(adapters) else { return }
        try? data.write(to: Self.registryURL, options: .atomic)
    }

    /// Copies a finished run's adapter into the adapters dir and records it. Copying means a run
    /// directory can be deleted without orphaning the registry entry.
    private func register(adapterAt src: String, variant: String, encoding: String,
                          rank: Int, steps: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { append("no adapter to register"); return }
        try? fm.createDirectory(at: Self.adaptersDir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(variant)-r\(rank)-s\(steps)-\(stamp)"
        // libsa3 resolves a bare name as lora-<name>-*.gguf in the adapters dir; we pass full
        // paths, but keeping the convention means the file also works from the CLI unchanged.
        let dst = Self.adaptersDir.appendingPathComponent("lora-\(name).gguf")
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: URL(fileURLWithPath: src), to: dst)
        } catch {
            append("adapter copy failed: \(error.localizedDescription)")
            return
        }
        adapters.insert(AdapterEntry(id: name, name: name, file: dst.lastPathComponent,
                                     variant: variant, encoding: encoding, rank: rank, steps: steps,
                                     created: Date(), target: "dit"), at: 0)
        saveRegistry()
        append("registered adapter \(name)")
    }

    /// DiT adapters must match the loaded variant; autoencoder adapters must match its SAME family.
    func adapters(for variant: String, target: String) -> [AdapterEntry] {
        let key = target == "dit" ? variant : sa3AutoencoderFamily(for: variant)
        return adapters.filter { $0.target == target && $0.variant == key }
    }

    /// Converts a .safetensors adapter to a gguf in-process and registers it. Decoder/encoder
    /// exports carry rank/alpha/adapter_type/target in their own __metadata__, so they need no
    /// json sidecar — pass nil and libsa3 reads the file's own config.
    @discardableResult
    func importAdapter(safetensors src: URL, target: String, base: String,
                       rank: Int, steps: Int, jsonSidecar: URL? = nil) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            append("no such adapter export: \(src.lastPathComponent)"); return false
        }
        try? fm.createDirectory(at: Self.adaptersDir, withIntermediateDirectories: true)
        let name = src.deletingPathExtension().lastPathComponent
        let dst = Self.adaptersDir.appendingPathComponent("lora-\(name).gguf")
        if adapters.contains(where: { $0.id == name }) && fm.fileExists(atPath: dst.path) {
            return true                                    // already imported
        }
        var err = [CChar](repeating: 0, count: 1024)
        let rc = src.path.withCString { sp -> Int32 in
            dst.path.withCString { op -> Int32 in
                if let jsonSidecar {
                    return jsonSidecar.path.withCString { jp in
                        sa3_convert_lora(sp, jp, op, &err, Int32(err.count))
                    }
                }
                return sa3_convert_lora(sp, nil, op, &err, Int32(err.count))
            }
        }
        guard rc == 0 else {
            append("convert failed for \(name): \(String(cString: err))"); return false
        }
        adapters.insert(AdapterEntry(id: name, name: name, file: dst.lastPathComponent,
                                     variant: base, encoding: "f32", rank: rank, steps: steps,
                                     created: Date(), target: target), at: 0)
        saveRegistry()
        append("imported \(target) adapter \(name)")
        return true
    }

    /// Re-registers gguf adapters present on disk but absent from the registry. They go missing when
    /// the registry is rewritten without them — which is what an earlier build did, having persisted
    /// absolute container paths that went stale across a reinstall. Names follow register()'s
    /// convention, lora-<variant>-r<rank>-s<steps>-<stamp>.gguf, so the metadata is recoverable.
    func recoverOrphanedAdapters() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.adaptersDir,
                                                      includingPropertiesForKeys: nil) else { return }
        var recovered = 0
        for f in files where f.pathExtension == "gguf" {
            let stem = f.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("lora-") else { continue }
            let name = String(stem.dropFirst("lora-".count))
            if adapters.contains(where: { $0.file == f.lastPathComponent }) { continue }

            // lora-<variant>-r<rank>-s<steps>-<stamp>: parse from the right so a variant
            // containing dashes ("small-music") stays intact.
            let parts = name.split(separator: "-").map(String.init)
            var variant = name, rank = 0, steps = 0, target = "dit"
            if parts.count >= 4, parts[parts.count - 3].hasPrefix("r"),
               parts[parts.count - 2].hasPrefix("s"),
               let r = Int(parts[parts.count - 3].dropFirst()),
               let st = Int(parts[parts.count - 2].dropFirst()) {
                rank = r; steps = st
                variant = parts[0..<(parts.count - 3)].joined(separator: "-")
            } else {
                // Not our training convention — an imported autoencoder adapter.
                target = name.lowercased().contains("declora") ? "decoder" : "dit"
                variant = name.lowercased().hasPrefix("same-l") ? "same-l" : "same-s"
            }
            let created = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            adapters.append(AdapterEntry(id: name, name: name, file: f.lastPathComponent,
                                         variant: variant, encoding: "unknown", rank: rank,
                                         steps: steps, created: created, target: target))
            recovered += 1
        }
        if recovered > 0 {
            adapters.sort { $0.created > $1.created }
            saveRegistry()
            append("recovered \(recovered) adapter(s) from disk")
        }
    }

    /// Converts any .safetensors sitting in Documents/adapters/ that has not been imported yet.
    /// The bundled SAME-S decoder adapters are side-loaded there like the models are.
    func importPendingExports() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.adaptersDir,
                                                      includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "safetensors" {
            let stem = f.deletingPathExtension().lastPathComponent
            if adapters.contains(where: { $0.id == stem }) { continue }
            let cfg = sa3ReadAdapterConfig(f)
            // The checkpoint states its own target and base; the filename is only a fallback for
            // exports that predate the config block.
            let target = (cfg["target"] as? String)
                ?? (stem.lowercased().contains("declora") ? "decoder" : "dit")
            let rank = (cfg["rank"] as? Int) ?? 8
            let step = (cfg["step"] as? Int)
                ?? Int(stem.split(separator: "_").last?
                    .replacingOccurrences(of: "step", with: "") ?? "") ?? 0
            // An autoencoder adapter belongs to a SAME family, a DiT adapter to a variant.
            let declared = cfg["base_model"] as? String
            let base: String
            if target == "dit" {
                base = declared ?? "small-music"
            } else {
                base = declared ?? (stem.lowercased().hasPrefix("same-l") ? "same-l" : "same-s")
            }
            if let notes = cfg["notes"] as? String, !notes.isEmpty {
                append("\(stem): \(notes)")
            }
            let sidecar = f.deletingPathExtension().appendingPathExtension("json")
            importAdapter(safetensors: f, target: target, base: base, rank: rank, steps: step,
                          jsonSidecar: fm.fileExists(atPath: sidecar.path) ? sidecar : nil)
        }
    }

    func deleteAdapter(_ entry: AdapterEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        adapters.removeAll { $0.id == entry.id }
        saveRegistry()
    }

    // MARK: - lifecycle

    func load(variant: String = "small-music", encoding: String = "q4_k_m",
              textEncoding: String = "q8_0", aeEncoding: String = "f32",
              device: String? = nil) {
        guard ctx == nil else { return }
        status = .loading
        append("loading \(variant) (\(encoding), t5 \(textEncoding), ae \(aeEncoding))")
        let dir = Self.modelsDir.path
        let dev = device ?? Self.device
        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 1024)
            var cfg = sa3_config_ex()
            let handle: OpaquePointer? = dir.withCString { dirC in
                variant.withCString { varC in
                    encoding.withCString { encC in
                        dev.withCString { devC in
                            textEncoding.withCString { tencC in
                              aeEncoding.withCString { aencC in
                                cfg.config.models_dir = dirC
                                cfg.config.variant = varC
                                cfg.config.encoding = encC
                                cfg.device = dev.isEmpty ? nil : devC
                                // Explicit, not auto: auto prefers F16 and never picks a quantized
                                // tier, so it would load the 563 MB encoder over the 285 MB Q8_0 one
                                // as soon as both are present. On a 4 GB phone that margin matters.
                                cfg.text_encoder_encoding = tencC
                                // `encoding` used to drag SAME along with the DiT, so every
                                // quantized run also quantized the autoencoder. Now separate.
                                cfg.autoencoder_encoding = aencC
                                return sa3_init_ex(&cfg, &err, Int32(err.count))
                              }
                            }
                        }
                    }
                }
            }
            let message = String(cString: err)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let handle {
                    self.ctx = handle
                    self.loadedVariant = variant
                    self.status = .ready
                    self.append("ready — libsa3 \(String(cString: sa3_version()))")
                } else {
                    self.status = .failed(message)
                    self.append("load failed: \(message)")
                }
            }
        }
    }

    func unload() {
        guard let c = ctx else { return }
        ctx = nil
        loadedVariant = nil
        status = .idle
        queue.async { sa3_free(c) }
    }

    // MARK: - generate

    func generate(prompt: String, steps: Int32, seed: Int64, frames: Int32 = 128,
                  keepModels: Bool = true,
                  loras: [(AdapterEntry, Float)] = [],
                  completion: @escaping (URL?) -> Void) {
        guard let c = ctx else { completion(nil); return }
        status = .working("generating")
        progress = 0
        let live = CallbackBox(self)
        activeBox = live
        let box = Unmanaged.passRetained(live).toOpaque()

        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 1024)
            var out = sa3_audio()
            var req = sa3_request_ex()
            req.request.steps = steps
            req.request.seed = seed
            req.request.frames = frames
            // Resident keeps T5 + DiT + SAME loaded (lowest latency, peak = their sum). Frugal frees
            // T5 before sampling and the DiT before decode, so peak is the largest single net
            // instead — the difference between ~1.45 GB and ~0.9 GB for f16 small-music.
            req.request.keep_models = keepModels ? 1 : 0
            req.decode_chunk_size = 128
            req.decode_overlap = 32
            req.request.user = box
            req.request.on_progress = { user, stage, step, total, fraction in
                guard let user else { return }
                let b = Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue()
                let s = stage.map { String(cString: $0) } ?? ""
                Task { @MainActor in
                    b.engine?.progress = Double(fraction)
                    b.engine?.status = .working("\(s) \(step)/\(total)")
                }
            }
            req.cancel_user = box
            req.should_cancel = { user in
                guard let user else { return 0 }
                let b = Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue()
                return b.cancelled ? 1 : 0
            }

            // Adapters apply over the base for this call only, so they are per-request rather than
            // bound at load. Passing full paths skips libsa3's lora-<name>-*.gguf lookup, and each
            // gguf carries its own lora.target, so a DiT and a decoder adapter can go in the same
            // array and libsa3 routes each onto the right network without being told which is which.
            let paths = loras.map { $0.0.path }
            let strengths = loras.map { $0.1 }
            let rc = prompt.withCString { p -> Int32 in
                req.request.prompt = p
                guard !paths.isEmpty else {
                    return sa3_generate_ex(c, &req, &out, &err, Int32(err.count))
                }
                // Each withCString is only valid inside its own closure, so build the array of
                // C strings by recursing rather than collecting pointers that would dangle.
                func withPaths(_ i: Int, _ acc: [UnsafePointer<CChar>?],
                               _ body: ([UnsafePointer<CChar>?]) -> Int32) -> Int32 {
                    if i == paths.count { return body(acc) }
                    return paths[i].withCString { cp in
                        withPaths(i + 1, acc + [cp], body)
                    }
                }
                return withPaths(0, []) { names in
                    names.withUnsafeBufferPointer { nb in
                        strengths.withUnsafeBufferPointer { sb in
                            req.request.n_loras = Int32(names.count)
                            req.request.lora_names = nb.baseAddress
                            req.request.lora_strengths = sb.baseAddress
                            return sa3_generate_ex(c, &req, &out, &err, Int32(err.count))
                        }
                    }
                }
            }
            let message = String(cString: err)
            var url: URL?
            if rc == 0 {
                url = Self.writeWav(out)
                sa3_free_audio(&out)
            }
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = rc == 0 ? .ready : .failed(message)
                self.append(rc == 0 ? "generated \(url?.lastPathComponent ?? "")" : "generate failed: \(message)")
                completion(url)
            }
        }
    }

    // MARK: - train

    func train(dataset: URL, output: URL, steps: Int32, variant: String = "small-music",
               encoding: String = "q4_k_m", textEncoding: String = "q8_0",
               aeEncoding: String = "f32",
               frames: Int32 = 64, rank: Int32 = 16, learningRate: Float = 2e-4,
               evictTextEncoder: Bool = true, device: String? = nil) {
        // sa3_train loads its own models on its own backend and needs no sa3_context. Leaving the
        // inference context alive would put a SECOND Metal backend beside it for the whole run --
        // two residency sets, two command queues, and after a keep_models generate a full second
        // set of weights. On a 4 GB device that is what exhausts the GPU. Drop it first; `queue`
        // is serial, so sa3_free runs before the training block starts.
        if ctx != nil {
            append("unloading inference context; training loads its own models")
            unload()
        }
        status = .working("training")
        lastStep = nil
        let live = CallbackBox(self)
        activeBox = live
        let box = Unmanaged.passRetained(live).toOpaque()
        let modelsPath = Self.modelsDir.path
        let dev = device ?? Self.device

        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 1024)
            var res = sa3_train_result()
            var cfg = sa3_train_config()
            cfg.steps = steps
            // Crop length dominates activation memory for the backward pass, so it is the first
            // thing to shrink on a phone. 64 frames ~= 5.9 s against the library's 512 (~47.6 s).
            cfg.frames = frames
            cfg.rank = rank
            cfg.learning_rate = learningRate
            cfg.seed = 42
            cfg.checkpoint_every = 100
            // Drops T5 between batches of captions: one encoder reload per window in exchange for
            // ~285 MB (Q8_0) resident across the run. Off by default in libsa3, on here — this is
            // the memory-bound host the flag was added for. Needs pre_encode, which is always on
            // through the C ABI (its pre_encode field only ever sets the flag true).
            cfg.evict_text_encoder = evictTextEncoder ? 1 : 0

            var hooks = sa3_train_hooks()
            hooks.user = box
            hooks.on_log = { user, line in
                guard let user, let line else { return }
                let b = Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue()
                let s = String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return }
                Task { @MainActor in b.engine?.append(s) }
            }
            hooks.on_step = { user, step in
                guard let user, let step = step?.pointee else { return }
                let b = Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue()
                let s = TrainStep(step: Int(step.step), maxSteps: Int(step.max_steps),
                                  loss: step.loss, gradNorm: step.grad_norm,
                                  seconds: step.step_seconds)
                Task { @MainActor in
                    b.engine?.lastStep = s
                    if s.maxSteps > 0 { b.engine?.progress = Double(s.step) / Double(s.maxSteps) }
                    b.engine?.status = .working("training \(s.step)/\(s.maxSteps)")
                }
            }
            hooks.should_cancel = { user in
                guard let user else { return 0 }
                return Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue().cancelled ? 1 : 0
            }

            let rc = dataset.path.withCString { ds in
                output.path.withCString { outp in
                    modelsPath.withCString { md in
                        variant.withCString { v in
                            dev.withCString { dv in
                                encoding.withCString { encC in
                                    textEncoding.withCString { tencC in
                                      aeEncoding.withCString { aencC in
                                        cfg.dataset_dir = ds
                                        cfg.output_dir = outp
                                        cfg.models_dir = md
                                        cfg.variant = v
                                        cfg.device = dev.isEmpty ? nil : dv
                                        // Both default to a heavier tier when left NULL: `encoding`
                                        // to f16, and the text encoder to auto (which prefers f16
                                        // and never picks a quantized one). Quantized bases train.
                                        cfg.encoding = encC
                                        cfg.text_encoder_encoding = tencC
                                        // pre_encode bakes the autoencoder's loss into the latents
                                        // the adapter learns from, so this matters more here.
                                        cfg.autoencoder_encoding = aencC
                                        return sa3_train(&cfg, &hooks, &res, &err, Int32(err.count))
                                      }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let message = String(cString: err)
            let adapter = withUnsafeBytes(of: res.final_adapter) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let cancelled = res.cancelled != 0
            let mean = res.mean_step_seconds
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if rc == 0 {
                    // .idle, not .ready: training unloaded the inference context and loads its own
                    // models, so nothing is resident afterwards. Reporting .ready would enable
                    // generate against a null ctx, which silently does nothing.
                    self.status = .idle
                    self.append(cancelled ? "training cancelled" : "training done")
                    self.append(String(format: "mean %.3fs/step", mean))
                    self.append("adapter: \((adapter as NSString).lastPathComponent)")
                    // A cancelled run still writes a final adapter, so it is worth registering.
                    self.register(adapterAt: adapter, variant: variant, encoding: encoding,
                                  rank: Int(rank), steps: Int(res.steps))
                } else {
                    self.status = .failed(message)
                    self.append("train failed: \(message)")
                }
            }
        }
    }

    func cancel() {
        activeBox?.cancel()
        append("cancel requested")
    }

    // MARK: - helpers

    fileprivate func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// libsa3 hands back PLANAR float samples; write a 16-bit interleaved WAV for AVAudioPlayer.
    private static func writeWav(_ audio: sa3_audio) -> URL? {
        guard let samples = audio.samples, audio.n_samp > 0, audio.n_ch > 0 else { return nil }
        let n = Int(audio.n_samp), ch = Int(audio.n_ch)
        var pcm = [Int16](repeating: 0, count: n * ch)
        for s in 0..<n {
            for c in 0..<ch {
                let v = max(-1.0, min(1.0, samples[c * n + s]))
                pcm[s * ch + c] = Int16(v * 32767.0)
            }
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(ch))
        u32(UInt32(audio.sample_rate)); u32(UInt32(audio.sample_rate * Int32(ch) * 2))
        u16(UInt16(ch * 2)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("out-\(Int(Date().timeIntervalSince1970)).wav")
        try? data.write(to: url)
        return url
    }
}

/// Bridges a Swift object into the C callbacks' `void* user`.
///
/// `cancelled` is read from libsa3's worker thread and written from the main actor, so it carries
/// its own lock rather than reaching back into the engine — hopping actors inside a C callback is
/// not an option, and assuming isolation there would trap.
final class CallbackBox {
    private let lock = NSLock()
    private var _cancelled = false

    weak var engineRef: SA3Engine?
    init(_ e: SA3Engine) { engineRef = e }

    @MainActor var engine: SA3Engine? { engineRef }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}
