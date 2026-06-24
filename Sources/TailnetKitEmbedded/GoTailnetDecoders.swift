import Foundation
import TailnetKitCore

struct GoTailnetEventPayload: Decodable {
    let type: String
    let url: String?
    let msg: String?

    func asTailnetEvent() -> TailnetEvent? {
        switch type {
        case "login_url":
            guard let urlString = url, let loginURL = URL(string: urlString) else { return nil }
            return .loginURL(loginURL)
        case "error":
            return .error(msg ?? "Tailnet error")
        case "state":
            if let msg, let state = GoTailnetStateDecoder.decodeStatePayload(msg) {
                return .state(state)
            }
            return .state(.starting)
        default:
            return nil
        }
    }
}

enum GoTailnetStateDecoder {
    static func decodeStateJSON(_ json: String?) -> TailnetState {
        guard let json, !json.isEmpty else { return .stopped }
        guard let data = json.data(using: .utf8) else { return .failed("Invalid state encoding") }
        guard let goState = try? JSONDecoder().decode(GoStatePayload.self, from: data) else {
            return .failed("Invalid state JSON")
        }
        return map(goState)
    }

    static func decodeStatePayload(_ payload: String) -> TailnetState? {
        if payload == "starting" {
            return .starting
        }
        guard let data = payload.data(using: .utf8),
              let goState = try? JSONDecoder().decode(GoStatePayload.self, from: data)
        else {
            return nil
        }
        return map(goState)
    }

    private static func map(_ goState: GoStatePayload) -> TailnetState {
        switch goState.phase {
        case "stopped":
            return .stopped
        case "starting":
            return .starting
        case "needs_login":
            if let urlString = goState.url, let url = URL(string: urlString) {
                return .needsLogin(url)
            }
            return .failed(goState.msg ?? "Login required")
        case "needs_device_approval":
            return .needsDeviceApproval
        case "running":
            return .running(
                TailnetIdentity(
                    hostname: goState.hostName ?? "",
                    dnsName: goState.dnsName,
                    ipv4: goState.ipv4,
                    ipv6: goState.ipv6,
                    addresses: [goState.ipv4, goState.ipv6].compactMap { $0 }
                )
            )
        case "failed":
            return .failed(goState.msg ?? "Tailnet failed")
        default:
            return .failed(goState.msg ?? "Unknown tailnet phase")
        }
    }
}

private struct GoStatePayload: Decodable {
    let phase: String
    let ipv4: String?
    let ipv6: String?
    let dnsName: String?
    let hostName: String?
    let msg: String?
    let url: String?
}
