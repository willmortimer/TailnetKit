import Foundation
import TailnetCore
import TailnetKitCore

/// Maps c-archive event structs into TailnetEvents and yields them onto the backend's
/// AsyncStream. Yields directly from the Go callback thread; AsyncStream.Continuation
/// is thread-safe, and consumers that need a specific actor hop there themselves.
final class GoEventSink: @unchecked Sendable {
    private let continuation: AsyncStream<TailnetEvent>.Continuation

    init(continuation: AsyncStream<TailnetEvent>.Continuation) {
        self.continuation = continuation
    }

    func handle(_ event: tnk_event) {
        guard let mapped = mapTailnetEvent(event) else {
            TailnetDebug.post("TailnetCore event unmapped kind=\(event.kind.rawValue)")
            return
        }
        continuation.yield(mapped)
    }
}

/// C callback registered with tnk_set_listener. Non-capturing so it converts to a C
/// function pointer; the GoEventSink is recovered from the opaque context. The event is
/// library-owned and transient, so handle() copies what it needs before returning.
func goEventTrampoline(_ ctx: UnsafeMutableRawPointer?, _ event: UnsafePointer<tnk_event>?) {
    guard let ctx, let event else { return }
    let sink = Unmanaged<GoEventSink>.fromOpaque(ctx).takeUnretainedValue()
    sink.handle(event.pointee)
}
