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
        let handle = bridgeBox.handle
        let connID = connID
        return try await TailnetBridgeExecutor.runIO {
            var buffer = [UInt8](repeating: 0, count: maxBytes)
            var count: Int32 = 0
            let err = buffer.withUnsafeMutableBytes { raw in
                tnk_conn_read(handle, connID, raw.baseAddress, Int32(maxBytes), &count)
            }
            if let msg = tnkError(err) {
                throw TailnetError.upstream(msg) // includes "EOF" when the connection ends
            }
            return Data(buffer.prefix(Int(count)))
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

    func close() async {
        let handle = bridgeBox.handle
        let connID = connID
        await TailnetBridgeExecutor.runIO {
            if let err = tnk_conn_close(handle, connID) { tnk_free(err) }
        }
    }
}
