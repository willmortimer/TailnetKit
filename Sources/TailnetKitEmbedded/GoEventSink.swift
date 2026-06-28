import Foundation
import TailnetCore
import TailnetKitCore

/// Decodes c-archive event JSON into TailnetEvents and yields them onto the backend's
/// AsyncStream. Yields directly from the Go callback thread; AsyncStream.Continuation
/// is thread-safe, and consumers that need a specific actor hop there themselves.
final class GoEventSink: @unchecked Sendable {
    private let continuation: AsyncStream<TailnetEvent>.Continuation

    init(continuation: AsyncStream<TailnetEvent>.Continuation) {
        self.continuation = continuation
    }

    func handle(_ json: String) {
        guard let data = json.data(using: .utf8) else {
            TailnetDebug.post("TailnetCore event missing JSON payload")
            return
        }
        guard let payload = try? JSONDecoder().decode(GoTailnetEventPayload.self, from: data) else {
            TailnetDebug.post("TailnetCore event decode failed: \(json)")
            return
        }
        guard let event = payload.asTailnetEvent() else {
            TailnetDebug.post("TailnetCore event unmapped type=\(payload.type): \(json)")
            return
        }
        continuation.yield(event)
    }
}

/// C callback registered with tnk_set_listener. Non-capturing so it converts to a C
/// function pointer; the GoEventSink is recovered from the opaque context. `json` is
/// transient (library-owned), so String(cString:) copies it before returning.
func goEventTrampoline(_ ctx: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) {
    guard let ctx, let json else { return }
    let sink = Unmanaged<GoEventSink>.fromOpaque(ctx).takeUnretainedValue()
    sink.handle(String(cString: json))
}
