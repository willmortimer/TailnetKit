// Package bridge exposes tsnet to Swift via gomobile bind.
package bridge

import (
	"encoding/json"
	"fmt"
	"sync"

	tailnet "github.com/ighostapp/ighost/Packages/TailnetKit/Go"
)

// EventListener receives tailnet lifecycle events as JSON (gomobile callback into Swift).
type EventListener interface {
	OnTailnetEvent(json string)
}

// Bridge wraps tailnet.Engine for gomobile.
type Bridge struct {
	mu       sync.Mutex
	opMu     sync.Mutex
	engine   *tailnet.Engine
	listener EventListener
}

// NewBridge constructs a tailnet bridge instance.
func NewBridge() *Bridge {
	b := &Bridge{}
	b.engine = tailnet.NewEngine(b.emit)
	return b
}

// SetListener registers the Swift/ObjC event callback (may be nil).
func (b *Bridge) SetListener(listener EventListener) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.listener = listener
}

func (b *Bridge) emit(ev tailnet.Event) {
	payload, err := json.Marshal(ev)
	if err != nil {
		return
	}
	b.mu.Lock()
	listener := b.listener
	b.mu.Unlock()
	if listener != nil {
		listener.OnTailnetEvent(string(payload))
	}
}

// Start boots tsnet for the profile JSON (TailnetProfile fields + stateDir path).
// Runs synchronously; serialized with other bridge entry points via opMu.
func (b *Bridge) Start(profileJSON string) (err error) {
	b.opMu.Lock()
	defer b.opMu.Unlock()

	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("tailnet start panic: %v", r)
			b.emit(tailnet.Event{Type: "error", Msg: err.Error()})
		}
	}()

	var profile tailnet.Profile
	if err := json.Unmarshal([]byte(profileJSON), &profile); err != nil {
		return err
	}
	return b.engine.Start(profile)
}

// Stop shuts down the profile's tsnet server.
func (b *Bridge) Stop(profileID string) error {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	return b.engine.Stop(profileID)
}

// StateJSON returns JSON-encoded tailnet.State for the profile.
func (b *Bridge) StateJSON(profileID string) (string, error) {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	return b.engine.StateJSON(profileID)
}

// PeersJSON returns JSON-encoded []tailnet.Peer for the profile.
func (b *Bridge) PeersJSON(profileID string) (string, error) {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	return b.engine.PeersJSON(profileID)
}

// DialTCP opens a TCP connection over the tailnet; returns an opaque connection id.
func (b *Bridge) DialTCP(profileID string, host string, port int64) (int64, error) {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	return b.engine.DialTCP(profileID, host, int(port))
}

// Read reads up to max bytes from a dialed connection.
// Not serialized with opMu: relay pumps need concurrent read/write on the same conn.
func (b *Bridge) Read(connID int64, max int64) ([]byte, error) {
	return b.engine.Read(connID, int(max))
}

// Write writes bytes to a dialed connection.
func (b *Bridge) Write(connID int64, data []byte) error {
	return b.engine.Write(connID, data)
}

// Close closes a dialed connection.
func (b *Bridge) Close(connID int64) error {
	return b.engine.Close(connID)
}

// OpenLoopbackRelay binds loopback TCP and proxies one client connection to host:port over tsnet.
func (b *Bridge) OpenLoopbackRelay(profileID string, host string, port int64) (int64, error) {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	p, err := b.engine.OpenLoopbackRelay(profileID, host, int(port))
	if err != nil {
		return 0, err
	}
	return int64(p), nil
}

// VerifySSHHostKey checks the host key fingerprint against peer SSH_HostKeys from tailnet status.
func (b *Bridge) VerifySSHHostKey(profileID string, hostname string, port int64, fingerprint string) bool {
	b.opMu.Lock()
	defer b.opMu.Unlock()
	ok, err := b.engine.VerifySSHHostKey(profileID, hostname, int(port), fingerprint)
	return err == nil && ok
}
