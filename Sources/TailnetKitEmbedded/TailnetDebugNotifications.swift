import Foundation
import TailnetKitCore

enum TailnetDebug {
    static func post(_ message: String) {
        print("[TailnetKit] \(message)")
    }
}
