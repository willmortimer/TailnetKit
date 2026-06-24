package tailnet

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
)

// OpenLoopbackRelay binds 127.0.0.1:0 and, on the first inbound TCP connection,
// dials host:port over tsnet and copies bytes in both directions (Go goroutines).
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

	log.Printf("[tailnetkit] relay: listening 127.0.0.1:%d → %s", relayPort, target)

	go func() {
		defer ln.Close()
		local, err := ln.Accept()
		if err != nil {
			log.Printf("[tailnetkit] relay: accept failed: %v", err)
			return
		}
		log.Printf("[tailnetkit] relay: local client connected from %s", local.RemoteAddr())

		remote, err := srv.Dial(context.Background(), "tcp", target)
		if err != nil {
			log.Printf("[tailnetkit] relay: dial %s failed: %v", target, err)
			local.Close()
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
	}()

	return relayPort, nil
}

func relayCopy(label string, dst io.Writer, src io.Reader) (int64, error) {
	_ = label
	return io.Copy(dst, src)
}
