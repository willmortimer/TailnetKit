package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/crypto/ssh"

	tailnet "github.com/ighostapp/ighost/Packages/TailnetKit/Go"
)

func main() {
	stateDir := flag.String("state", filepath.Join(os.TempDir(), "ighost-tailnet-cli"), "tsnet state directory")
	hostname := flag.String("hostname", "ighost-cli-dev", "tailnet hostname")
	controlURL := flag.String("control", "", "optional control server URL")
	host := flag.String("host", "", "peer hostname for dial/ssh")
	port := flag.Int("port", 22, "peer port")
	user := flag.String("user", os.Getenv("USER"), "ssh username for -ssh")
	trySSH := flag.Bool("ssh", false, "attempt Tailscale SSH with auth none after dial")
	flag.Parse()

	if flag.NArg() < 1 {
		fmt.Fprintf(os.Stderr, "usage: tailnet-cli <start|status|peers|dial> [flags]\n")
		os.Exit(2)
	}

	profile := tailnet.Profile{
		ID:          "main",
		DisplayName: "CLI",
		Hostname:    *hostname,
		ControlURL:  *controlURL,
		StateDir:    *stateDir,
	}

	engine := tailnet.NewEngine(func(ev tailnet.Event) {
		b, _ := json.Marshal(ev)
		fmt.Println(string(b))
	})

	cmd := flag.Arg(0)
	_ = context.Background()

	switch cmd {
	case "start":
		if err := engine.Start(profile); err != nil {
			fmt.Fprintf(os.Stderr, "start: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("started")
	case "status":
		if err := engine.Start(profile); err != nil {
			fmt.Fprintf(os.Stderr, "start: %v\n", err)
			os.Exit(1)
		}
		time.Sleep(500 * time.Millisecond)
		jsonStr, err := engine.StateJSON(profile.ID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "status: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(jsonStr)
	case "peers":
		if err := engine.Start(profile); err != nil {
			fmt.Fprintf(os.Stderr, "start: %v\n", err)
			os.Exit(1)
		}
		time.Sleep(500 * time.Millisecond)
		jsonStr, err := engine.PeersJSON(profile.ID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "peers: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(jsonStr)
	case "dial":
		if *host == "" {
			fmt.Fprintln(os.Stderr, "-host required")
			os.Exit(2)
		}
		if err := engine.Start(profile); err != nil {
			fmt.Fprintf(os.Stderr, "start: %v\n", err)
			os.Exit(1)
		}
		time.Sleep(1 * time.Second)
		connID, err := engine.DialTCP(profile.ID, *host, *port)
		if err != nil {
			fmt.Fprintf(os.Stderr, "dial: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("connected id=%d\n", connID)
		if *trySSH {
			if err := tryTailscaleSSH(engine, connID, *user); err != nil {
				fmt.Fprintf(os.Stderr, "ssh: %v\n", err)
				os.Exit(1)
			}
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		os.Exit(2)
	}
}

func tryTailscaleSSH(engine *tailnet.Engine, connID int64, user string) error {
	raw := &engineConn{engine: engine, id: connID}
	config := &ssh.ClientConfig{
		User:            user,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	}
	clientConn, chans, reqs, err := ssh.NewClientConn(raw, "tailscale", config)
	if err != nil {
		return err
	}
	client := ssh.NewClient(clientConn, chans, reqs)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		return err
	}
	defer session.Close()
	out, err := session.CombinedOutput("echo TAILNET_CLI_OK")
	if err != nil {
		return err
	}
	fmt.Print(string(out))
	return nil
}

type engineConn struct {
	engine *tailnet.Engine
	id     int64
}

func (c *engineConn) Read(b []byte) (int, error) {
	data, err := c.engine.Read(c.id, len(b))
	if err != nil {
		return 0, err
	}
	return copy(b, data), nil
}

func (c *engineConn) Write(b []byte) (int, error) {
	if err := c.engine.Write(c.id, b); err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *engineConn) Close() error { return c.engine.Close(c.id) }

func (c *engineConn) LocalAddr() net.Addr  { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }
func (c *engineConn) RemoteAddr() net.Addr { return &net.TCPAddr{IP: net.IPv4(100, 64, 0, 1), Port: 22} }

func (c *engineConn) SetDeadline(t time.Time) error      { return nil }
func (c *engineConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *engineConn) SetWriteDeadline(t time.Time) error { return nil }
