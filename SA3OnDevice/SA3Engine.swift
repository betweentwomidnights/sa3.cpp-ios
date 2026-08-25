import Foundation

/// Swift wrapper over the libsa3 C ABI (vendor/include/libsa3.h).
///
/// Everything here blocks, so callers run it off the main actor. libsa3 is not reentrant: one
/// generate or train at a time per context, which `queue` enforces.
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

    struct TrainStep: Equatable {
        var step: Int
        var maxSteps: Int
        var loss: Float
        var gradNorm: Double
        var seconds: Double
    }

    /// Where the gguf set lives. Models are too big to ship in the bundle for an experiment, so
    /// they are side-loaded into the app's Documents directory (see README).
    static var modelsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
    }

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

    // MARK: - lifecycle

    func load(variant: String = "small-music", encoding: String = "q4_k_m") {
        guard ctx == nil else { return }
        status = .loading
        append("loading \(variant) (\(encoding)) from \(Self.modelsDir.lastPathComponent)/")
        let dir = Self.modelsDir.path
        let dev = Self.device
        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 1024)
            var cfg = sa3_config_ex()
            let handle: OpaquePointer? = dir.withCString { dirC in
                variant.withCString { varC in
                    encoding.withCString { encC in
                        dev.withCString { devC in
                            cfg.config.models_dir = dirC
                            cfg.config.variant = varC
                            cfg.config.encoding = encC
                            cfg.device = dev.isEmpty ? nil : devC
                            cfg.text_encoder_encoding = nil   // auto: prefers F16
                            return sa3_init_ex(&cfg, &err, Int32(err.count))
                        }
                    }
                }
            }
            let message = String(cString: err)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let handle {
                    self.ctx = handle
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
        status = .idle
        queue.async { sa3_free(c) }
    }

    // MARK: - generate

    func generate(prompt: String, steps: Int32, seed: Int64, frames: Int32 = 128,
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
            req.request.keep_models = 1
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

            let rc = prompt.withCString { p -> Int32 in
                req.request.prompt = p
                return sa3_generate_ex(c, &req, &out, &err, Int32(err.count))
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

    func train(dataset: URL, output: URL, steps: Int32, variant: String = "small-music") {
        status = .working("training")
        lastStep = nil
        let live = CallbackBox(self)
        activeBox = live
        let box = Unmanaged.passRetained(live).toOpaque()
        let modelsPath = Self.modelsDir.path
        let dev = Self.device

        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 1024)
            var res = sa3_train_result()
            var cfg = sa3_train_config()
            cfg.steps = steps
            cfg.frames = 128
            cfg.seed = 42
            cfg.checkpoint_every = 100

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
                                cfg.dataset_dir = ds
                                cfg.output_dir = outp
                                cfg.models_dir = md
                                cfg.variant = v
                                cfg.device = dev.isEmpty ? nil : dv
                                return sa3_train(&cfg, &hooks, &res, &err, Int32(err.count))
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
                    self.status = .ready
                    self.append(cancelled ? "training cancelled" : "training done")
                    self.append(String(format: "mean %.3fs/step", mean))
                    self.append("adapter: \((adapter as NSString).lastPathComponent)")
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
