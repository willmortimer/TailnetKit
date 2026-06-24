import Foundation
import TailnetCore
import TailnetKitCore

/// Forwards gomobile JSON events into a TailnetKit AsyncStream (always onto the main queue for UI consumers).
final class GoEventListener: NSObject, BridgeEventListenerProtocol, @unchecked Sendable {
    private let continuation: AsyncStream<TailnetEvent>.Continuation

    init(continuation: AsyncStream<TailnetEvent>.Continuation) {
        self.continuation = continuation
    }

    func onTailnetEvent(_ json: String?) {
        guard let json, let data = json.data(using: .utf8) else {
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
        let continuation = self.continuation
        DispatchQueue.main.async {
            continuation.yield(event)
        }
    }
}
