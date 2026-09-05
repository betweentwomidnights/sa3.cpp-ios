import Foundation

/// The local, reversible audio workspace for the jam tab.
///
/// A generation or a recording establishes a new root; continue and transform derive from the take
/// in hand. Either way the take being replaced goes on the undo stack, which is what makes undo
/// instant and entirely local. There is deliberately no branching model here — one current take,
/// one stack behind it.
@MainActor
final class TakeSession: ObservableObject {

    enum Source: String {
        case create
        case recording
        case pads
        case edit
        case continuation
        case transformation

        var label: String {
            switch self {
            case .create: return "created"
            case .recording: return "recorded"
            case .pads: return "played"
            case .edit: return "edited"
            case .continuation: return "continued"
            case .transformation: return "transformed"
            }
        }
    }

    struct Take: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let source: Source
        let seed: UInt64?
        /// The prompt that produced it, empty for a recording. Carried on the take rather than
        /// read back off `SA3Settings` when it is needed: settings move on, and a take saved to
        /// the sample library would otherwise be labelled with whatever was typed since.
        let prompt: String
        let createdAt = Date()
    }

    @Published private(set) var current: Take?
    @Published private(set) var undoStack: [Take] = []

    var url: URL? { current?.url }
    var canUndo: Bool { !undoStack.isEmpty }

    /// A take that owes nothing to the current one: a generation from text, or a recording.
    ///
    /// The stack is kept rather than cleared. A new root is not derived from what came before, but
    /// the take before it is still on disk and still the thing you were working on — dropping the
    /// history means one stray tap on `record` costs you the jam.
    func beginRoot(_ url: URL, source: Source = .create, seed: UInt64? = nil,
                   prompt: String = "") {
        applyDerived(url, source: source, seed: seed, prompt: prompt)
    }

    /// Continue and transform: the new take replaces the current one, which goes on the stack.
    func applyDerived(_ url: URL, source: Source, seed: UInt64?, prompt: String = "") {
        if let current { undoStack.append(current) }
        self.current = Take(url: url, source: source, seed: seed, prompt: prompt)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        current = previous
    }

    func clear() {
        current = nil
        undoStack.removeAll()
    }
}
