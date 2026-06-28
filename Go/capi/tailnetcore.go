// Command tailnetcore exposes tsnet to Swift as a flat C ABI, built with
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

// protocolVersion is the C ABI version; Swift rejects a mismatch.
const protocolVersion = 1

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

func (b *bridge) emit(ev tailnet.Event) {
	payload, err := json.Marshal(ev)
	if err != nil {
		return
	}
	b.mu.Lock()
	cb, ctx := b.cb, b.ctx
	b.mu.Unlock()
	if cb == nil {
		return
	}
	cs := C.CString(string(payload))
	C.tnk_invoke_event_cb(cb, ctx, cs)
	C.free(unsafe.Pointer(cs))
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
func tnk_start(h C.longlong, profileJSON *C.char) (errStr *C.char) {
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
	var profile tailnet.Profile
	if err := json.Unmarshal([]byte(C.GoString(profileJSON)), &profile); err != nil {
		return cError(err)
	}
	return cError(b.engine.Start(profile))
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

//export tnk_state_json
func tnk_state_json(h C.longlong, profileID *C.char, outJSON **C.char) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	s, err := b.engine.StateJSON(C.GoString(profileID))
	if err != nil {
		return cError(err)
	}
	*outJSON = C.CString(s)
	return nil
}

//export tnk_peers_json
func tnk_peers_json(h C.longlong, profileID *C.char, outJSON **C.char) *C.char {
	b := lookup(h)
	if b == nil {
		return C.CString("invalid bridge handle")
	}
	b.opMu.Lock()
	defer b.opMu.Unlock()
	s, err := b.engine.PeersJSON(C.GoString(profileID))
	if err != nil {
		return cError(err)
	}
	*outJSON = C.CString(s)
	return nil
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
