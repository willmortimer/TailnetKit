// Command tailnetcore exposes tsnet to Swift as a flat, typed C ABI, built with
// `go build -buildmode=c-archive`. It wraps the same tailnet.Engine the gomobile
// bridge used; only the boundary differs. See tailnetcore.h for the public contract.
package main

/*
#include "bridge.h"
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"unsafe"

	tailnet "github.com/willmortimer/TailnetKit/Go"
)

// protocolVersion is the C ABI version; Swift rejects a mismatch. v2 = typed structs.
const protocolVersion = 2

// bridge pairs one engine with its registered event callback.
type bridge struct {
	mu     sync.Mutex // guards cb/ctx
	opMu   sync.Mutex // serializes control-plane calls, mirroring the gomobile bridge
	engine *tailnet.Engine
	cb     C.tnk_event_cb
	ctx    unsafe.Pointer
}

// Bridges live in a Go-side registry keyed by an integer handle. Only the handle
// crosses the boundary, so no Go pointers are handed to C.
var (
	registryMu sync.Mutex
	registry   = map[C.longlong]*bridge{}
	nextHandle C.longlong = 1
)

func lookup(h C.longlong) *bridge {
	registryMu.Lock()
	defer registryMu.Unlock()
	return registry[h]
}

// cError returns a malloc'd copy of err's message, or nil when err is nil. The
// caller owns the result and must release it with tnk_free.
func cError(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// cStringOrNil mallocs a C copy of s, or returns nil for the empty string.
func cStringOrNil(s string) *C.char {
	if s == "" {
		return nil
	}
	return C.CString(s)
}

func boolToC(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

func phaseToC(phase string) C.tnk_phase {
	switch phase {
	case "stopped":
		return C.TNK_PHASE_STOPPED
	case "starting":
		return C.TNK_PHASE_STARTING
	case "needs_login":
		return C.TNK_PHASE_NEEDS_LOGIN
	case "needs_device_approval":
		return C.TNK_PHASE_NEEDS_DEVICE_APPROVAL
	case "running":
		return C.TNK_PHASE_RUNNING
	default:
		return C.TNK_PHASE_FAILED
	}
}

// fillState populates a C state struct from a Go State. The string fields are
// library-owned; release them with tnk_free_state.
func fillState(out *C.tnk_state, st tailnet.State) {
	out.phase = phaseToC(st.Phase)
	out.ipv4 = cStringOrNil(st.IPv4)
	out.ipv6 = cStringOrNil(st.IPv6)
	out.dns_name = cStringOrNil(st.DNSName)
	out.host_name = cStringOrNil(st.HostName)
	out.url = cStringOrNil(st.URL)
	out.msg = cStringOrNil(st.Msg)
}

func (b *bridge) emit(ev tailnet.Event) {
	b.mu.Lock()
	cb, ctx := b.cb, b.ctx
	b.mu.Unlock()
	if cb == nil {
		return
	}

	var cev C.tnk_event
	switch ev.Type {
	case "login_url":
		cev.kind = C.TNK_EVENT_LOGIN_URL
		cev.url = cStringOrNil(ev.URL)
	case "error":
		cev.kind = C.TNK_EVENT_ERROR
		cev.msg = cStringOrNil(ev.Msg)
	case "state":
		cev.kind = C.TNK_EVENT_STATE
		fillState(&cev.state, decodeStateMsg(ev.Msg))
	default:
		return
	}

	C.tnk_invoke_event_cb(cb, ctx, &cev)

	C.free(unsafe.Pointer(cev.url))
	C.free(unsafe.Pointer(cev.msg))
	freeState(&cev.state)
}

// decodeStateMsg turns an engine "state" event payload into a typed State. The
// engine encodes state as JSON inside Event.Msg (except the bare "starting"); this
// keeps the engine untouched while the C boundary stays typed.
func decodeStateMsg(msg string) tailnet.State {
	if msg == "starting" {
		return tailnet.State{Phase: "starting"}
	}
	var st tailnet.State
	if err := json.Unmarshal([]byte(msg), &st); err != nil {
		return tailnet.State{Phase: "failed", Msg: msg}
	}
	return st
}

//export tnk_protocol_version
func tnk_protocol_version() C.int {
	return C.int(protocolVersion)
}

//export tnk_new_bridge
func tnk_new_bridge() C.longlong {
	b := &bridge{}
	b.engine = tailnet.NewEngine(b.emit)
	registryMu.Lock()
	h := nextHandle
	nextHandle++
	registry[h] = b
	registryMu.Unlock()
	return h
}

//export tnk_free_bridge
func tnk_free_bridge(h C.longlong) {
	registryMu.Lock()
	delete(registry, h)
	registryMu.Unlock()
}

//export tnk_set_listener
func tnk_set_listener(h C.longlong, cb C.tnk_event_cb, ctx unsafe.Pointer) {
	b := lookup(h)
	if b == nil {
		return
	}
	b.mu.Lock()
	b.cb = cb
	b.ctx = ctx
	b.mu.Unlock()
}

//export tnk_start
func tnk_start(h C.longlong, profile *C.tnk_profile) (errStr *C.char) {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			msg := fmt.Sprintf("tailnet start panic: %v", r)
			b.emit(tailnet.Event{Type: "error", Msg: msg})
			errStr = C.CString(msg)
		}
	}()
	p := tailnet.Profile{
		ID:          C.GoString(profile.id),
		DisplayName: C.GoString(profile.display_name),
		Hostname:    C.GoString(profile.hostname),
		ControlURL:  C.GoString(profile.control_url),
		StateDir:    C.GoString(profile.state_dir),
	}
	return cError(b.engine.Start(p))
}

//export tnk_stop
func tnk_stop(h C.longlong, profileID *C.char) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	return cError(b.engine.Stop(C.GoString(profileID)))
}

//export tnk_get_state
func tnk_get_state(h C.longlong, profileID *C.char, out *C.tnk_state) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	st, err := b.engine.Status(C.GoString(profileID))
	if err != nil {
		return cError(err)
	}
	fillState(out, st)
	return nil
}

//export tnk_free_state
func tnk_free_state(s *C.tnk_state) {
	if s == nil {
		return
	}
	freeState(s)
}

func freeState(s *C.tnk_state) {
	C.free(unsafe.Pointer(s.ipv4))
	C.free(unsafe.Pointer(s.ipv6))
	C.free(unsafe.Pointer(s.dns_name))
	C.free(unsafe.Pointer(s.host_name))
	C.free(unsafe.Pointer(s.url))
	C.free(unsafe.Pointer(s.msg))
	s.ipv4, s.ipv6, s.dns_name, s.host_name, s.url, s.msg = nil, nil, nil, nil, nil, nil
}

//export tnk_get_peers
func tnk_get_peers(h C.longlong, profileID *C.char, outPeers **C.tnk_peer, outCount *C.int) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	peers, err := b.engine.Peers(C.GoString(profileID))
	if err != nil {
		return cError(err)
	}
	n := len(peers)
	*outCount = C.int(n)
	if n == 0 {
		*outPeers = nil
		return nil
	}
	arr := (*C.tnk_peer)(C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.tnk_peer{}))))
	slice := unsafe.Slice(arr, n)
	for i, p := range peers {
		slice[i].id = cStringOrNil(p.ID)
		slice[i].dns_name = cStringOrNil(p.DNSName)
		slice[i].host_name = cStringOrNil(p.HostName)
		slice[i].tailscale_ip = cStringOrNil(p.TailscaleIP)
		slice[i].os = cStringOrNil(p.OS)
		slice[i].online = boolToC(p.Online)
		slice[i].ssh_enabled = boolToC(p.SSHEnabled)
	}
	*outPeers = arr
	return nil
}

//export tnk_free_peers
func tnk_free_peers(peers *C.tnk_peer, count C.int) {
	if peers == nil {
		return
	}
	slice := unsafe.Slice(peers, int(count))
	for i := range slice {
		C.free(unsafe.Pointer(slice[i].id))
		C.free(unsafe.Pointer(slice[i].dns_name))
		C.free(unsafe.Pointer(slice[i].host_name))
		C.free(unsafe.Pointer(slice[i].tailscale_ip))
		C.free(unsafe.Pointer(slice[i].os))
	}
	C.free(unsafe.Pointer(peers))
}

//export tnk_dial_tcp
func tnk_dial_tcp(h C.longlong, profileID *C.char, host *C.char, port C.int, outConn *C.longlong) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	id, err := b.engine.DialTCP(C.GoString(profileID), C.GoString(host), int(port))
	if err != nil {
		return cError(err)
	}
	*outConn = C.longlong(id)
	return nil
}

// tnk_conn_read / write / close intentionally skip opMu: the relay needs concurrent
// read and write on the same connection, matching the gomobile bridge.

//export tnk_conn_read
func tnk_conn_read(h C.longlong, connID C.longlong, buf unsafe.Pointer, max C.int, outN *C.int) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	data, err := b.engine.Read(int64(connID), int(max))
	if err != nil {
		return cError(err)
	}
	dst := unsafe.Slice((*byte)(buf), int(max))
	n := copy(dst, data)
	*outN = C.int(n)
	return nil
}

//export tnk_conn_write
func tnk_conn_write(h C.longlong, connID C.longlong, data unsafe.Pointer, length C.int) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	return cError(b.engine.Write(int64(connID), C.GoBytes(data, length)))
}

//export tnk_conn_close
func tnk_conn_close(h C.longlong, connID C.longlong) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	return cError(b.engine.Close(int64(connID)))
}

//export tnk_open_loopback_relay
func tnk_open_loopback_relay(h C.longlong, profileID *C.char, host *C.char, port C.int, outPort *C.int) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	p, err := b.engine.OpenLoopbackRelay(C.GoString(profileID), C.GoString(host), int(port))
	if err != nil {
		return cError(err)
	}
	*outPort = C.int(p)
	return nil
}

//export tnk_verify_ssh_host_key
func tnk_verify_ssh_host_key(h C.longlong, profileID *C.char, hostname *C.char, port C.int, fingerprint *C.char) C.int {
	b := lookup(h)
	if b == nil {
		return 0
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	ok, err := b.engine.VerifySSHHostKey(C.GoString(profileID), C.GoString(hostname), int(port), C.GoString(fingerprint))
	if err != nil || !ok {
		return 0
	}
	return 1
}

//export tnk_free
func tnk_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
