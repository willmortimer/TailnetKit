import Foundation
import TailnetCore

/// Owns a Go c-archive bridge handle and the event-callback context. The handle is a
/// plain integer, but the Go control path is not reentrancy-safe, so callers route
/// through TailnetBridgeExecutor. The event context is retained for the bridge's
/// lifetime and released after the listener is cleared.
final class TailnetBridgeBox: @unchecked Sendable {
    let handle: tnk_bridge
    private let context: UnsafeMutableRawPointer

    init?(sink: GoEventSink) {
        let h = tnk_new_bridge()
        guard h != 0 else { return nil }
        self.handle = h
        self.context = Unmanaged.passRetained(sink).toOpaque()
        tnk_set_listener(h, goEventTrampoline, context)
    }

    deinit {
        tnk_set_listener(handle, nil, nil) // locks the same mutex emit() does: no callback races past here
        tnk_free_bridge(handle)
        Unmanaged<GoEventSink>.fromOpaque(context).release()
    }
}

/// Maps a c-archive return value to a Swift error message. The library returns NULL on
/// success or a malloc'd string on failure; this frees the string and yields its text.
func tnkError(_ cstr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let cstr else { return nil }
    defer { tnk_free(cstr) }
    return String(cString: cstr)
}

/// Serializes tsnet control-plane calls; connection I/O uses a concurrent queue for full-duplex relay.
enum TailnetBridgeExecutor {
    private static let controlQueue = DispatchQueue(label: "TailnetKit.bridge.control")
    private static let ioQueue = DispatchQueue(label: "TailnetKit.bridge.io", attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                continuation.resume(returning: body())
            }
        }
    }

    static func runIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runIO<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: body())
            }
        }
    }
}
