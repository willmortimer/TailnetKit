import Foundation
import TailnetCore
import TailnetKitCore

/// Connected UDP socket over the embedded node. Go keeps packet boundaries.
final class GoTailnetDatagramConnection: TailnetDatagramConnection, @unchecked Sendable {
    private let bridgeBox: TailnetBridgeBox
    private let connID: Int64

    init(bridgeBox: TailnetBridgeBox, connID: Int64) {
        self.bridgeBox = bridgeBox
        self.connID = connID
    }

    func receive() async throws -> Data {
        let handle = bridgeBox.handle
        let id = connID
        return try await withTaskCancellationHandler {
            try await TailnetBridgeExecutor.runIO {
                var buffer = [UInt8](repeating: 0, count: 65_535)
                var count: Int32 = 0
                let error = buffer.withUnsafeMutableBytes { raw in
                    tnk_datagram_receive(handle, id, raw.baseAddress, Int32(raw.count), &count)
                }
                if let message = tnkError(error) { throw TailnetError.upstream(message) }
                return Data(buffer.prefix(Int(count)))
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func send(_ data: Data) async throws {
        guard (1...65_507).contains(data.count) else {
            throw TailnetError.upstream("invalid datagram size")
        }
        let handle = bridgeBox.handle
        let id = connID
        try await TailnetBridgeExecutor.runIO {
            let error = data.withUnsafeBytes { raw in
                tnk_datagram_send(handle, id, raw.baseAddress, Int32(raw.count))
            }
            if let message = tnkError(error) { throw TailnetError.upstream(message) }
        }
    }

    func close() async {
        let handle = bridgeBox.handle
        let id = connID
        await TailnetBridgeExecutor.runIO {
            if let error = tnk_conn_close(handle, id) { tnk_free(error) }
        }
    }
}
