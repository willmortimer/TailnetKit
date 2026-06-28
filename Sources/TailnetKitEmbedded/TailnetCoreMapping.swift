import Foundation
import TailnetCore
import TailnetKitCore

// Conversions between the TailnetCore C structs and TailnetKit's Swift models. All
// reads copy out of library-owned memory; the caller frees the C side afterward.

private func cstr(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    return String(cString: p)
}

func mapTailnetState(_ s: tnk_state) -> TailnetState {
    let ipv4 = cstr(s.ipv4)
    let ipv6 = cstr(s.ipv6)
    let dnsName = cstr(s.dns_name)
    let hostName = cstr(s.host_name)
    let url = cstr(s.url)
    let msg = cstr(s.msg)

    if s.phase == TNK_PHASE_STOPPED { return .stopped }
    if s.phase == TNK_PHASE_STARTING { return .starting }
    if s.phase == TNK_PHASE_NEEDS_LOGIN {
        if let url, let parsed = URL(string: url) { return .needsLogin(parsed) }
        return .failed(msg ?? "Login required")
    }
    if s.phase == TNK_PHASE_NEEDS_DEVICE_APPROVAL { return .needsDeviceApproval }
    if s.phase == TNK_PHASE_RUNNING {
        return .running(
            TailnetIdentity(
                hostname: hostName ?? "",
                dnsName: dnsName,
                ipv4: ipv4,
                ipv6: ipv6,
                addresses: [ipv4, ipv6].compactMap { $0 }
            )
        )
    }
    return .failed(msg ?? "Tailnet failed")
}

func mapTailnetPeer(_ p: tnk_peer) -> TailnetPeer {
    TailnetPeer(
        id: cstr(p.id) ?? "",
        dnsName: cstr(p.dns_name) ?? "",
        hostName: cstr(p.host_name) ?? "",
        tailscaleIP: cstr(p.tailscale_ip) ?? "",
        os: cstr(p.os),
        online: p.online != 0,
        sshEnabled: p.ssh_enabled != 0
    )
}

func mapTailnetEvent(_ event: tnk_event) -> TailnetEvent? {
    if event.kind == TNK_EVENT_LOGIN_URL {
        guard let urlString = cstr(event.url), let url = URL(string: urlString) else { return nil }
        return .loginURL(url)
    }
    if event.kind == TNK_EVENT_ERROR {
        return .error(cstr(event.msg) ?? "Tailnet error")
    }
    if event.kind == TNK_EVENT_STATE {
        return .state(mapTailnetState(event.state))
    }
    return nil
}

/// Builds a tnk_profile whose C strings stay valid for the body call. The pointers are
/// stack-scoped, so this must be invoked synchronously around the tnk_start call (not
/// across an await).
func withTnkProfile<R>(
    id: String,
    displayName: String,
    hostname: String,
    controlURL: String?,
    stateDir: String,
    _ body: (UnsafePointer<tnk_profile>) throws -> R
) rethrows -> R {
    try id.withCString { idC in
        try displayName.withCString { nameC in
            try hostname.withCString { hostC in
                try stateDir.withCString { dirC in
                    func make(_ controlC: UnsafePointer<CChar>?) throws -> R {
                        var profile = tnk_profile(
                            id: idC,
                            display_name: nameC,
                            hostname: hostC,
                            control_url: controlC,
                            state_dir: dirC
                        )
                        return try withUnsafePointer(to: &profile) { try body($0) }
                    }
                    if let controlURL {
                        return try controlURL.withCString { try make($0) }
                    }
                    return try make(nil)
                }
            }
        }
    }
}
