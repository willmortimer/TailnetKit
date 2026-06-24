import Foundation
import TailnetKit

enum TailnetDebug {
    static func post(_ message: String) {
        print("[TailnetKit] \(message)")
    }
}
