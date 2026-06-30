import Foundation
import TailnetKitCore

enum TailnetDebug {
    static func post(_ message: String) {
        TailnetLog.debug(message)
    }
}
