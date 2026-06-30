import Foundation
import os

/// TailnetKit's operational log sink. Defaults to an `os.Logger`; set `handler` once at
/// launch to route logs into your own logging stack (swift-log, file, analytics, …).
///
/// TailnetKit's own log lines are operational only and never contain credentials, auth
/// URLs, or keys, so the default logger marks them `.public`. If you forward them, apply
/// whatever redaction policy your app requires.
public enum TailnetLog {
    private static let defaultLogger = Logger(subsystem: "TailnetKit", category: "tailnet")

    /// Replace to capture TailnetKit's logs. Set once during app startup.
    public nonisolated(unsafe) static var handler: @Sendable (String) -> Void = { message in
        defaultLogger.debug("\(message, privacy: .public)")
    }

    public static func debug(_ message: String) {
        handler(message)
    }
}
