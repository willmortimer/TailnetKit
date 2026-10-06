import Foundation

/// Synchronous lifecycle for one tailnet profile.
///
/// Backends must apply `beginStart` before their first suspension. A reentrant
/// `configure` then sees `.starting` and cannot swap in a different identity
/// while the bridge is still bringing the previous one up.
public struct TailnetRuntimePhase: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case idle
        case configured(TailnetProfile)
        case starting(TailnetProfile)
        case running(TailnetProfile)
        case stopping(TailnetProfile)
    }

    public enum StartDirective: Sendable, Equatable {
        case start(TailnetProfile)
        case joinInFlight
        case alreadyRunning
        case afterStop
    }

    public enum StopDirective: Sendable, Equatable {
        case none
        case stop(TailnetProfile, interruptedStart: Bool)
        case joinInFlight
    }

    public private(set) var value: Value

    public init() {
        value = .idle
    }

    public var profile: TailnetProfile? {
        switch value {
        case .idle:
            return nil
        case .configured(let profile), .starting(let profile), .running(let profile), .stopping(let profile):
            return profile
        }
    }

    public var isRunning: Bool {
        if case .running = value { return true }
        return false
    }

    /// Same-profile updates keep the current phase. A different profile is only
    /// accepted from `idle` or `configured`.
    public mutating func configure(_ profile: TailnetProfile) throws {
        switch value {
        case .idle, .configured:
            value = .configured(profile)
        case .starting(let current), .running(let current), .stopping(let current):
            guard current.id == profile.id else {
                throw TailnetError.identityAlreadyRunning
            }
            switch value {
            case .starting:
                value = .starting(profile)
            case .running:
                value = .running(profile)
            case .stopping:
                value = .stopping(profile)
            case .idle, .configured:
                break
            }
        }
    }

    public mutating func beginStart() throws -> StartDirective {
        switch value {
        case .idle:
            throw TailnetError.notConfigured
        case .configured(let profile):
            value = .starting(profile)
            return .start(profile)
        case .starting:
            return .joinInFlight
        case .running:
            return .alreadyRunning
        case .stopping:
            return .afterStop
        }
    }

    /// Marks the bridge start as running. Returns false when `stop` already moved
    /// the phase to `.stopping`, so the caller must not claim the node is up.
    @discardableResult
    public mutating func finishStart(profileID: UUID) -> Bool {
        guard case .starting(let profile) = value, profile.id == profileID else {
            return false
        }
        value = .running(profile)
        return true
    }

    public mutating func failStart(profileID: UUID) {
        guard case .starting(let profile) = value, profile.id == profileID else {
            return
        }
        value = .configured(profile)
    }

    public mutating func beginStop() -> StopDirective {
        switch value {
        case .idle, .configured:
            return .none
        case .stopping:
            return .joinInFlight
        case .starting(let profile):
            value = .stopping(profile)
            return .stop(profile, interruptedStart: true)
        case .running(let profile):
            value = .stopping(profile)
            return .stop(profile, interruptedStart: false)
        }
    }

    public mutating func finishStop(profileID: UUID) {
        guard case .stopping(let profile) = value, profile.id == profileID else {
            return
        }
        value = .configured(profile)
    }

    public mutating func destroy() {
        value = .idle
    }
}
