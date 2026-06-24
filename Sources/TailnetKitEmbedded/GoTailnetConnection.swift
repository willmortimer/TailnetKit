import Foundation
import TailnetCore
import TailnetKitCore

final class GoTailnetConnection: TailnetConnection, @unchecked Sendable {
    private let bridgeBox: TailnetBridgeBox
    private let connID: Int64

    init(bridgeBox: TailnetBridgeBox, connID: Int64) {
        self.bridgeBox = bridgeBox
        self.connID = connID
    }

    func read(maxBytes: Int) async throws -> Data {
        let box = bridgeBox
        let connID = connID
        return try await TailnetBridgeExecutor.runIO {
            try box.bridge.read(connID, max: Int64(maxBytes))
        }
    }

    func write(_ data: Data) async throws {
        let box = bridgeBox
        let connID = connID
        try await TailnetBridgeExecutor.runIO {
            try box.bridge.write(connID, data: data)
        }
    }

    func close() async {
        let box = bridgeBox
        let connID = connID
        _ = await TailnetBridgeExecutor.runIO {
            try? box.bridge.close(connID)
        }
    }
}
