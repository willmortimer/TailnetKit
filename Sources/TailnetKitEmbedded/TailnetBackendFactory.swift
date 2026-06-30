import Foundation
import TailnetKitCore

/// Selects the tailnet backend available in this build. Returns the lazy embedded
/// backend, which defers Go bridge construction (and its failure modes) until first use.
public enum TailnetBackendFactory {
    public static func makeDefault() -> any TailnetBackend {
        LazyGoTailnetBackend()
    }
}
