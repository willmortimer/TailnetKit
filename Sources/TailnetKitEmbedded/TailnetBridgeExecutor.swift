import Foundation
import TailnetCore

/// Holds gomobile bridge; TailnetBridgeExecutor serializes access (BridgeBridge is not Sendable).
final class TailnetBridgeBox: @unchecked Sendable {
    let bridge: BridgeBridge
    init(bridge: BridgeBridge) { self.bridge = bridge }
}

/// Serializes tsnet control-plane calls; connection I/O uses a concurrent queue for full-duplex relay.
enum TailnetBridgeExecutor {
    private static let controlQueue = DispatchQueue(label: "com.ighost.tailnet.bridge.control")
    private static let ioQueue = DispatchQueue(label: "com.ighost.tailnet.bridge.io", attributes: .concurrent)

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
