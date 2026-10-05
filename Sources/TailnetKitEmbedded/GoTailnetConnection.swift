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
        guard (1...1_048_576).contains(maxBytes) else {
            throw TailnetError.upstream("invalid read size")
        }
        let handle = bridgeBox.handle
        let connID = connID
        return try await withTaskCancellationHandler {
            try await TailnetBridgeExecutor.runIO {
            var buffer = [UInt8](repeating: 0, count: maxBytes)
            var count: Int32 = 0
            let err = buffer.withUnsafeMutableBytes { raw in
                tnk_conn_read(handle, connID, raw.baseAddress, Int32(maxBytes), &count)
            }
            if let msg = tnkError(err) {
                throw TailnetError.upstream(msg)
            }
            return Data(buffer.prefix(Int(count)))
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func write(_ data: Data) async throws {
        let handle = bridgeBox.handle
        let connID = connID
        try await TailnetBridgeExecutor.runIO {
            let err = data.withUnsafeBytes { raw in
                tnk_conn_write(handle, connID, raw.baseAddress, Int32(data.count))
            }
            if let msg = tnkError(err) {
                throw TailnetError.upstream(msg)
            }
        }
    }

    func finishWriting() async throws {
        let handle = bridgeBox.handle
        let connID = connID
        try await TailnetBridgeExecutor.runIO {
            if let msg = tnkError(tnk_conn_close_write(handle, connID)) {
                throw TailnetError.upstream(msg)
            }
        }
    }

    func close() async {
        let handle = bridgeBox.handle
        let connID = connID
        await TailnetBridgeExecutor.runIO {
            if let err = tnk_conn_close(handle, connID) { tnk_free(err) }
        }
    }
}
