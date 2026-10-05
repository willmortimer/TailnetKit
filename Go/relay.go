package tailnet

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"sync"

	"tailscale.com/tsnet"
)

// OpenLoopbackRelay accepts multiple local clients. CloseRelay or Stop releases
// the listener; active client connections finish independently.
func (e *Engine) OpenLoopbackRelay(profileID, host string, port int) (int, error) {
	e.mu.Lock()
	srv, ok := e.servers[profileID]
	e.mu.Unlock()
	if !ok {
		return 0, fmt.Errorf("tailnet not started")
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	relayPort := ln.Addr().(*net.TCPAddr).Port
	target := net.JoinHostPort(host, strconv.Itoa(port))
	e.mu.Lock()
	if e.servers[profileID] != srv {
		e.mu.Unlock()
		_ = ln.Close()
		return 0, fmt.Errorf("tailnet stopped while opening relay")
	}
	e.relays[relayPort] = ownedRelay{profileID: profileID, listener: ln}
	e.mu.Unlock()

	log.Printf("[tailnetkit] relay: listening 127.0.0.1:%d → %s", relayPort, target)

	go func() {
		defer e.CloseRelay(relayPort)
		for {
			local, err := ln.Accept()
			if err != nil {
				return
			}
			go serveRelayClient(srv, local, target)
		}
	}()

	return relayPort, nil
}

func (e *Engine) CloseRelay(port int) error {
	e.mu.Lock()
	relay, ok := e.relays[port]
	if ok {
		delete(e.relays, port)
	}
	e.mu.Unlock()
	if !ok {
		return nil
	}
	return relay.listener.Close()
}

func serveRelayClient(srv *tsnet.Server, local net.Conn, target string) {
	log.Printf("[tailnetkit] relay: local client connected from %s", local.RemoteAddr())

	ctx, cancel := context.WithTimeout(context.Background(), tcpDialTimeout)
	defer cancel()
	remote, err := srv.Dial(ctx, "tcp", target)
	if err != nil {
		log.Printf("[tailnetkit] relay: dial %s failed: %v", target, err)
		_ = local.Close()
		return
	}
	log.Printf("[tailnetkit] relay: dialed %s OK", target)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, err := relayCopy("client→tailnet", remote, local)
		if err != nil && err != io.EOF {
			log.Printf("[tailnetkit] relay: client→tailnet: %v", err)
		}
		if c, ok := remote.(interface{ CloseWrite() error }); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, err := relayCopy("tailnet→client", local, remote)
		if err != nil && err != io.EOF {
			log.Printf("[tailnetkit] relay: tailnet→client: %v", err)
		}
		if c, ok := local.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
	_ = local.Close()
	_ = remote.Close()

}

func relayCopy(label string, dst io.Writer, src io.Reader) (int64, error) {
	_ = label
	return io.Copy(dst, src)
}
