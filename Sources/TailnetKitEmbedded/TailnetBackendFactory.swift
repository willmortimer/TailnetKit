import Foundation
import TailnetKitCore

/// Selects the tailnet backend available in this build.
public enum TailnetBackendFactory {
    public static func makeDefault() -> any TailnetBackend {
        GoTailnetBackend()
    }
}
