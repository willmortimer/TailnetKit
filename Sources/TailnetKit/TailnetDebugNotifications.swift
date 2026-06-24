import Foundation

extension Notification.Name {
    /// Posted when TailnetCore emits an event Swift failed to decode. `userInfo["message"]` is human-readable.
    public static let tailnetDebugMessage = Notification.Name("com.ighost.tailnet.debug")
}
