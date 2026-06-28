package tailnet

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// Profile configures one embedded tsnet node.
type Profile struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Hostname    string `json:"hostname"`
	ControlURL  string `json:"controlURL,omitempty"`
	StateDir    string `json:"stateDir"`
}

// Event is emitted to Swift via callback.
type Event struct {
	Type string `json:"type"`
	URL  string `json:"url,omitempty"`
	Msg  string `json:"msg,omitempty"`
}

// Peer is a simplified tailnet peer for the iOS UI.
type Peer struct {
	ID          string `json:"id"`
	DNSName     string `json:"dnsName"`
	HostName    string `json:"hostName"`
	TailscaleIP string `json:"tailscaleIP"`
	OS          string `json:"os,omitempty"`
	Online      bool   `json:"online"`
	SSHEnabled  bool   `json:"sshEnabled"`
}

// State describes tailnet lifecycle for Swift.
type State struct {
	Phase    string `json:"phase"`
	IPv4     string `json:"ipv4,omitempty"`
	IPv6     string `json:"ipv6,omitempty"`
	DNSName  string `json:"dnsName,omitempty"`
	HostName string `json:"hostName,omitempty"`
	Msg      string `json:"msg,omitempty"`
	URL      string `json:"url,omitempty"`
}

// Engine wraps one or more tsnet servers (v1: one profile).
type Engine struct {
	mu       sync.Mutex
	servers  map[string]*tsnet.Server
	conns    map[int64]net.Conn
	nextID   int64
	emit     func(Event)
}

func NewEngine(emit func(Event)) *Engine {
	return &Engine{
		servers: make(map[string]*tsnet.Server),
		conns:   make(map[int64]net.Conn),
		emit:    emit,
	}
}

func (e *Engine) Start(profile Profile) error {
	e.mu.Lock()
	if _, exists := e.servers[profile.ID]; exists {
		e.mu.Unlock()
		return nil
	}

	srv := &tsnet.Server{
		Dir:        profile.StateDir,
		Hostname:   profile.Hostname,
		ControlURL: profile.ControlURL,
	}
	e.servers[profile.ID] = srv
	e.mu.Unlock()

	e.emit(Event{Type: "state", Msg: "starting"})

	if err := srv.Start(); err != nil {
		e.mu.Lock()
		delete(e.servers, profile.ID)
		e.mu.Unlock()
		e.emit(Event{Type: "error", Msg: err.Error()})
		return err
	}

	// tsnet.Up() waits only for ipn.Running and ignores NeedsLogin, so interactive
	// login would block forever. Poll LocalClient status until we can proceed.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	st, err := e.waitForInteractive(ctx, srv)
	if err != nil {
		e.mu.Lock()
		delete(e.servers, profile.ID)
		e.mu.Unlock()
		e.emit(Event{Type: "error", Msg: err.Error()})
		return err
	}

	return e.emitStatusOutcome(st)
}

// waitForInteractive polls until login URL, device approval, running, or ctx timeout.
func (e *Engine) waitForInteractive(ctx context.Context, srv *tsnet.Server) (*ipnstate.Status, error) {
	lc, err := srv.LocalClient()
	if err != nil {
		return nil, fmt.Errorf("LocalClient: %w", err)
	}

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		st, err := lc.Status(ctx)
		if err != nil {
			return nil, fmt.Errorf("status: %w", err)
		}
		if done, outcome := classifyStatus(st); done {
			return outcome, nil
		}

		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("timed out waiting for tailnet (last backend=%q authURL=%q)", st.BackendState, st.AuthURL)
		case <-ticker.C:
		}
	}
}

func classifyStatus(st *ipnstate.Status) (done bool, stOut *ipnstate.Status) {
	if st == nil {
		return false, nil
	}
	switch st.BackendState {
	case "Running":
		if len(st.TailscaleIPs) > 0 {
			return true, st
		}
	case "NeedsLogin":
		if st.AuthURL != "" {
			return true, st
		}
	case "NeedsMachineAuth":
		return true, st
	}
	return false, nil
}

func (e *Engine) emitStatusOutcome(st *ipnstate.Status) error {
	if st == nil {
		return fmt.Errorf("tailnet: empty status")
	}
	switch st.BackendState {
	case "NeedsMachineAuth":
		approval, _ := json.Marshal(State{Phase: "needs_device_approval"})
		e.emit(Event{Type: "state", Msg: string(approval)})
		return nil
	case "NeedsLogin":
		if st.AuthURL == "" {
			return fmt.Errorf("tailnet: NeedsLogin but no AuthURL")
		}
		e.emit(Event{Type: "login_url", URL: st.AuthURL})
		needsLogin, _ := json.Marshal(State{Phase: "needs_login", URL: st.AuthURL})
		e.emit(Event{Type: "state", Msg: string(needsLogin)})
		return nil
	case "Running":
		e.emitRunning("", st)
		return nil
	default:
		return fmt.Errorf("tailnet: unexpected backend state %q", st.BackendState)
	}
}

func (e *Engine) Stop(profileID string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	srv, ok := e.servers[profileID]
	if !ok {
		return nil
	}
	delete(e.servers, profileID)
	for id, conn := range e.conns {
		_ = conn.Close()
		delete(e.conns, id)
	}
	return srv.Close()
}

func (e *Engine) StateJSON(profileID string) (string, error) {
	st, err := e.status(profileID)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(st)
	return string(b), err
}

// Status returns typed lifecycle state for the profile (typed C boundary).
func (e *Engine) Status(profileID string) (State, error) {
	return e.status(profileID)
}

// Peers returns the typed peer list for the profile (typed C boundary).
func (e *Engine) Peers(profileID string) ([]Peer, error) {
	return e.peers(profileID)
}

func (e *Engine) status(profileID string) (State, error) {
	e.mu.Lock()
	srv, ok := e.servers[profileID]
	e.mu.Unlock()
	if !ok {
		return State{Phase: "stopped"}, nil
	}

	ctx := context.Background()
	lc, err := srv.LocalClient()
	if err != nil {
		return State{Phase: "failed", Msg: err.Error()}, nil
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return State{Phase: "failed", Msg: err.Error()}, nil
	}

	if st.BackendState == "NeedsLogin" && st.AuthURL != "" {
		return State{Phase: "needs_login", URL: st.AuthURL}, nil
	}
	if st.BackendState == "NeedsMachineAuth" {
		return State{Phase: "needs_device_approval"}, nil
	}
	if len(st.TailscaleIPs) > 0 {
		return State{
			Phase:    "running",
			IPv4:     pickIPv4(st),
			IPv6:     pickIPv6(st),
			DNSName:  selfDNSName(st),
			HostName: selfHostName(st),
		}, nil
	}
	return State{Phase: "starting"}, nil
}

func (e *Engine) PeersJSON(profileID string) (string, error) {
	peers, err := e.peers(profileID)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(peers)
	return string(b), err
}

func (e *Engine) peers(profileID string) ([]Peer, error) {
	e.mu.Lock()
	srv, ok := e.servers[profileID]
	e.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("tailnet not started")
	}

	lc, err := srv.LocalClient()
	if err != nil {
		return nil, err
	}
	st, err := lc.Status(context.Background())
	if err != nil {
		return nil, err
	}

	var out []Peer
	for _, p := range st.Peer {
		out = append(out, mapPeer(p))
	}
	return out, nil
}

func mapPeer(p *ipnstate.PeerStatus) Peer {
	ip := ""
	if len(p.TailscaleIPs) > 0 {
		ip = p.TailscaleIPs[0].String()
	}
	sshHint := p.OS == "linux" || p.OS == "macOS" || p.OS == "darwin"
	return Peer{
		ID:          string(p.ID),
		DNSName:     p.DNSName,
		HostName:    p.HostName,
		TailscaleIP: ip,
		OS:          p.OS,
		Online:      p.Online,
		SSHEnabled:  sshHint,
	}
}

func (e *Engine) DialTCP(profileID, host string, port int) (int64, error) {
	e.mu.Lock()
	srv, ok := e.servers[profileID]
	e.mu.Unlock()
	if !ok {
		return 0, fmt.Errorf("tailnet not started")
	}

	addr := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := srv.Dial(context.Background(), "tcp", addr)
	if err != nil {
		return 0, err
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	id := e.nextID
	e.nextID++
	e.conns[id] = conn
	return id, nil
}

func (e *Engine) Read(id int64, max int) ([]byte, error) {
	conn := e.getConn(id)
	if conn == nil {
		return nil, fmt.Errorf("unknown connection %d", id)
	}
	buf := make([]byte, max)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}
	return buf[:n], nil
}

func (e *Engine) Write(id int64, data []byte) error {
	conn := e.getConn(id)
	if conn == nil {
		return fmt.Errorf("unknown connection %d", id)
	}
	_, err := conn.Write(data)
	return err
}

func (e *Engine) Close(id int64) error {
	e.mu.Lock()
	conn, ok := e.conns[id]
	if ok {
		delete(e.conns, id)
	}
	e.mu.Unlock()
	if !ok {
		return nil
	}
	return conn.Close()
}

func (e *Engine) getConn(id int64) net.Conn {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.conns[id]
}

func (e *Engine) emitRunning(profileID string, st *ipnstate.Status) {
	phase := State{
		Phase:    "running",
		IPv4:     pickIPv4(st),
		IPv6:     pickIPv6(st),
		DNSName:  selfDNSName(st),
		HostName: selfHostName(st),
	}
	b, _ := json.Marshal(phase)
	e.emit(Event{Type: "state", Msg: string(b)})
}

func selfDNSName(st *ipnstate.Status) string {
	if st.Self == nil {
		return ""
	}
	return st.Self.DNSName
}

func selfHostName(st *ipnstate.Status) string {
	if st.Self == nil {
		return ""
	}
	return st.Self.HostName
}

func pickIPv4(st *ipnstate.Status) string {
	for _, ip := range st.TailscaleIPs {
		if ip.Is4() {
			return ip.String()
		}
	}
	return ""
}

func pickIPv6(st *ipnstate.Status) string {
	for _, ip := range st.TailscaleIPs {
		if ip.Is6() {
			return ip.String()
		}
	}
	return ""
}
