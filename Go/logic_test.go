package tailnet

import (
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
)

func runningStatus() *ipnstate.Status {
	return &ipnstate.Status{
		BackendState: "Running",
		TailscaleIPs: []netip.Addr{
			netip.MustParseAddr("100.64.0.5"),
			netip.MustParseAddr("fd7a:115c:a1e0::1"),
		},
		Self: &ipnstate.PeerStatus{DNSName: "self.example.ts.net.", HostName: "self"},
	}
}

func TestPickIPs(t *testing.T) {
	st := runningStatus()
	if got := pickIPv4(st); got != "100.64.0.5" {
		t.Errorf("pickIPv4 = %q, want 100.64.0.5", got)
	}
	if got := pickIPv6(st); got != "fd7a:115c:a1e0::1" {
		t.Errorf("pickIPv6 = %q, want fd7a:115c:a1e0::1", got)
	}
	empty := &ipnstate.Status{}
	if pickIPv4(empty) != "" || pickIPv6(empty) != "" {
		t.Error("pick on empty status should be empty")
	}
}

func TestSelfNames(t *testing.T) {
	st := runningStatus()
	if selfDNSName(st) != "self.example.ts.net." {
		t.Errorf("selfDNSName = %q", selfDNSName(st))
	}
	if selfHostName(st) != "self" {
		t.Errorf("selfHostName = %q", selfHostName(st))
	}
	if selfDNSName(&ipnstate.Status{}) != "" || selfHostName(&ipnstate.Status{}) != "" {
		t.Error("self names with nil Self should be empty")
	}
}

func TestClassifyStatus(t *testing.T) {
	cases := []struct {
		name string
		st   *ipnstate.Status
		done bool
	}{
		{"nil", nil, false},
		{"running with ip", runningStatus(), true},
		{"running without ip", &ipnstate.Status{BackendState: "Running"}, false},
		{"needs login with url", &ipnstate.Status{BackendState: "NeedsLogin", AuthURL: "https://login"}, true},
		{"needs login without url", &ipnstate.Status{BackendState: "NeedsLogin"}, false},
		{"needs machine auth", &ipnstate.Status{BackendState: "NeedsMachineAuth"}, true},
		{"starting", &ipnstate.Status{BackendState: "Starting"}, false},
	}
	for _, c := range cases {
		if done, _ := classifyStatus(c.st); done != c.done {
			t.Errorf("%s: done = %v, want %v", c.name, done, c.done)
		}
	}
}

func TestMapPeer(t *testing.T) {
	p := &ipnstate.PeerStatus{
		ID:           "n123",
		DNSName:      "box.example.ts.net.",
		HostName:     "box",
		OS:           "linux",
		Online:       true,
		TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.9")},
	}
	got := mapPeer(p)
	if got.ID != "n123" || got.HostName != "box" || got.TailscaleIP != "100.64.0.9" || !got.Online {
		t.Errorf("mapPeer mismatch: %+v", got)
	}
	if !got.SSHEnabled {
		t.Error("linux peer should hint SSHEnabled")
	}
	if mapPeer(&ipnstate.PeerStatus{OS: "windows"}).SSHEnabled {
		t.Error("windows peer should not hint SSHEnabled")
	}
}

func TestPeerMatchesHost(t *testing.T) {
	peer := &ipnstate.PeerStatus{
		DNSName:      "box.example.ts.net.",
		HostName:     "box",
		TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.9")},
	}
	for _, host := range []string{"box", "box.example.ts.net", "100.64.0.9"} {
		if !peerMatchesHost(peer, host) {
			t.Errorf("expected match for %q", host)
		}
	}
	if peerMatchesHost(peer, "other") {
		t.Error("unexpected match for 'other'")
	}
}

func TestOpenSSHLineFingerprintSHA256(t *testing.T) {
	line := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPg0OhwmYHV4qfg5v4A2L5VKRojTayE+j6XSGk2XVARU test@tailnetkit"
	fp, err := openSSHLineFingerprintSHA256(line)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fp) != 64 || strings.ToLower(fp) != fp {
		t.Errorf("fingerprint not 64-char lowercase hex: %q", fp)
	}
	fp2, _ := openSSHLineFingerprintSHA256(line)
	if fp != fp2 {
		t.Error("fingerprint should be deterministic")
	}
	if _, err := openSSHLineFingerprintSHA256("not a valid key line"); err == nil {
		t.Error("expected error for invalid key line")
	}
}
