package tailnet

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"golang.org/x/crypto/ssh"
	"tailscale.com/ipn/ipnstate"
)

func (e *Engine) VerifySSHHostKey(profileID, hostname string, port int, fingerprintSHA256 string) (bool, error) {
	_ = port
	e.mu.Lock()
	srv, ok := e.servers[profileID]
	e.mu.Unlock()
	if !ok {
		return false, fmt.Errorf("tailnet not started")
	}

	lc, err := srv.LocalClient()
	if err != nil {
		return false, err
	}
	st, err := lc.Status(context.Background())
	if err != nil {
		return false, err
	}

	want := strings.ToLower(strings.TrimSpace(fingerprintSHA256))
	host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(hostname)), ".")

	for _, peer := range st.Peer {
		if peer == nil || !peerMatchesHost(peer, host) {
			continue
		}
		for _, line := range peer.SSH_HostKeys {
			fp, err := openSSHLineFingerprintSHA256(line)
			if err != nil {
				continue
			}
			if fp == want {
				return true, nil
			}
		}
		return false, nil
	}
	return false, nil
}

func peerMatchesHost(peer *ipnstate.PeerStatus, host string) bool {
	dns := strings.TrimSuffix(strings.ToLower(peer.DNSName), ".")
	if dns == host || strings.HasPrefix(dns, host+".") {
		return true
	}
	if strings.EqualFold(peer.HostName, host) {
		return true
	}
	for _, ip := range peer.TailscaleIPs {
		if strings.EqualFold(ip.String(), host) {
			return true
		}
	}
	return false
}

func openSSHLineFingerprintSHA256(line string) (string, error) {
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(pub.Marshal())
	return hex.EncodeToString(sum[:]), nil
}
