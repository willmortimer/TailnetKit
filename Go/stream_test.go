package tailnet

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

// streamTestConn is a deterministic net.Conn test double. It deliberately uses
// only the interface surface consumed by Engine so these tests never start tsnet.
type streamTestConn struct {
	mu          sync.Mutex
	readData    []byte
	readEOF     bool
	eofReturned bool
	writeData   bytes.Buffer
	maxWrite    int
	closed      bool
	writeClosed bool
}

func (c *streamTestConn) Read(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.readData) == 0 {
		return 0, io.EOF
	}
	n := copy(p, c.readData)
	c.readData = c.readData[n:]
	if len(c.readData) == 0 && c.readEOF && !c.eofReturned {
		c.eofReturned = true
		return n, io.EOF
	}
	return n, nil
}

func (c *streamTestConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.writeClosed {
		return 0, net.ErrClosed
	}
	n := len(p)
	if c.maxWrite > 0 && n > c.maxWrite {
		n = c.maxWrite
	}
	_, _ = c.writeData.Write(p[:n])
	return n, nil
}

func (c *streamTestConn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	return nil
}

func (c *streamTestConn) CloseWrite() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return net.ErrClosed
	}
	c.writeClosed = true
	return nil
}

func (*streamTestConn) LocalAddr() net.Addr              { return testAddr("local") }
func (*streamTestConn) RemoteAddr() net.Addr             { return testAddr("remote") }
func (*streamTestConn) SetDeadline(time.Time) error      { return nil }
func (*streamTestConn) SetReadDeadline(time.Time) error  { return nil }
func (*streamTestConn) SetWriteDeadline(time.Time) error { return nil }

type testAddr string

func (a testAddr) Network() string { return "test" }
func (a testAddr) String() string  { return string(a) }

func engineWithTestConn(profileID string, conn net.Conn) (*Engine, int64) {
	e := NewEngine(nil)
	e.conns[1] = ownedConn{profileID: profileID, conn: conn}
	e.nextID = 2
	return e, 1
}

func TestReadNormalizesCleanEOF(t *testing.T) {
	conn := &streamTestConn{readData: []byte("terminal output"), readEOF: true}
	e, id := engineWithTestConn("profile", conn)

	got, err := e.Read(id, 64)
	if err != nil || string(got) != "terminal output" {
		t.Fatalf("Read() = %q, %v; want payload and nil error", got, err)
	}

	got, err = e.Read(id, 64)
	if err != nil || len(got) != 0 {
		t.Fatalf("Read() at EOF = %q, %v; want empty payload and nil error", got, err)
	}
}

func TestWriteCompletesShortWrites(t *testing.T) {
	conn := &streamTestConn{maxWrite: 3}
	e, id := engineWithTestConn("profile", conn)
	want := []byte("short writes must be retried")

	if err := e.Write(id, want); err != nil {
		t.Fatalf("Write() error: %v", err)
	}
	if got := conn.writeData.String(); got != string(want) {
		t.Fatalf("written bytes = %q, want %q", got, want)
	}
}

func TestCloseWriteUsesHalfClose(t *testing.T) {
	conn := &streamTestConn{}
	e, id := engineWithTestConn("profile", conn)

	if err := e.CloseWrite(id); err != nil {
		t.Fatalf("CloseWrite() error: %v", err)
	}
	if !conn.writeClosed {
		t.Fatal("CloseWrite() did not half-close the write side")
	}
	if conn.closed {
		t.Fatal("CloseWrite() closed the full connection")
	}
}

func TestStopClosesOnlyConnectionsOwnedByProfile(t *testing.T) {
	profileConn := &streamTestConn{}
	otherConn := &streamTestConn{}
	e := NewEngine(nil)
	e.servers = map[string]*tsnet.Server{
		"profile-a": {},
		"profile-b": {},
	}
	e.conns = map[int64]ownedConn{
		1: {profileID: "profile-a", conn: profileConn},
		2: {profileID: "profile-b", conn: otherConn},
	}
	e.nextID = 3

	if err := e.Stop("profile-a"); err != nil {
		t.Fatalf("Stop(profile-a) error: %v", err)
	}
	if !profileConn.closed {
		t.Fatal("stopping profile-a did not close its connection")
	}
	if otherConn.closed {
		t.Fatal("stopping profile-a closed profile-b's connection")
	}
	if _, ok := e.conns[1]; ok {
		t.Fatal("stopped profile connection remains registered")
	}
	if _, ok := e.conns[2]; !ok {
		t.Fatal("other profile connection was removed")
	}

	if err := e.Stop("profile-b"); err != nil {
		t.Fatalf("Stop(profile-b) error: %v", err)
	}
	if !otherConn.closed {
		t.Fatal("stopping profile-b did not close its connection")
	}
}

func TestCloseWriteRejectsConnectionsWithoutHalfClose(t *testing.T) {
	e, id := engineWithTestConn("profile", &noHalfCloseConn{})
	if err := e.CloseWrite(id); err == nil {
		t.Fatal("CloseWrite() succeeded on a connection without half-close")
	}
}

func TestCloseRelayUnblocksAccept(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	e := NewEngine(nil)
	e.relays[port] = ownedRelay{profileID: "profile", listener: listener}

	accepted := make(chan error, 1)
	go func() {
		_, acceptErr := listener.Accept()
		accepted <- acceptErr
	}()
	time.Sleep(20 * time.Millisecond)
	if err := e.CloseRelay(port); err != nil {
		t.Fatalf("CloseRelay: %v", err)
	}
	select {
	case err := <-accepted:
		if err == nil {
			t.Fatal("Accept succeeded after CloseRelay")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Accept still blocked after CloseRelay")
	}
	if _, ok := e.relays[port]; ok {
		t.Fatal("closed relay is still registered")
	}
}

func TestConcurrentCloseRelayIsIdempotent(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	e := NewEngine(nil)
	e.relays[port] = ownedRelay{profileID: "profile", listener: listener}

	var wg sync.WaitGroup
	wg.Add(8)
	for range 8 {
		go func() {
			defer wg.Done()
			if err := e.CloseRelay(port); err != nil {
				t.Errorf("CloseRelay: %v", err)
			}
		}()
	}
	wg.Wait()
	if _, ok := e.relays[port]; ok {
		t.Fatal("relay still registered after concurrent close")
	}
}

func TestStopClosesOnlyRelaysOwnedByProfile(t *testing.T) {
	ownedListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	otherListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer otherListener.Close()
	ownedPort := ownedListener.Addr().(*net.TCPAddr).Port
	otherPort := otherListener.Addr().(*net.TCPAddr).Port
	e := NewEngine(nil)
	e.servers = map[string]*tsnet.Server{
		"profile-a": {},
		"profile-b": {},
	}
	e.relays[ownedPort] = ownedRelay{profileID: "profile-a", listener: ownedListener}
	e.relays[otherPort] = ownedRelay{profileID: "profile-b", listener: otherListener}

	if err := e.Stop("profile-a"); err != nil {
		t.Fatalf("Stop(profile-a): %v", err)
	}
	if _, err := ownedListener.Accept(); err == nil {
		t.Fatal("stopping profile-a left its relay accepting")
	}
	dialed := make(chan struct{})
	go func() {
		if conn, err := net.Dial("tcp", otherListener.Addr().String()); err == nil {
			_ = conn.Close()
		}
		close(dialed)
	}()
	conn, err := otherListener.Accept()
	if err != nil {
		t.Fatalf("other profile relay was closed: %v", err)
	}
	_ = conn.Close()
	<-dialed
	if _, ok := e.relays[otherPort]; !ok {
		t.Fatal("stopping profile-a removed profile-b's relay")
	}
}

func TestDatagramSizeAndNetworkGuards(t *testing.T) {
	udp := &streamTestConn{}
	e := NewEngine(nil)
	e.conns[1] = ownedConn{profileID: "profile", conn: udp, network: "udp"}
	tcpEngine, tcpID := engineWithTestConn("profile", &streamTestConn{})

	if err := e.WriteDatagram(1, nil); err == nil {
		t.Fatal("empty datagram was accepted")
	}
	if err := e.WriteDatagram(1, make([]byte, 65508)); err == nil {
		t.Fatal("oversized datagram was accepted")
	}
	if err := tcpEngine.WriteDatagram(tcpID, []byte("nope")); err == nil {
		t.Fatal("stream connection accepted a datagram write")
	}
	if _, err := tcpEngine.ReadDatagram(tcpID); err == nil {
		t.Fatal("stream connection accepted a datagram read")
	}
}

func TestDatagramWriteAndEOF(t *testing.T) {
	conn := &streamTestConn{readData: []byte("pkt"), readEOF: true, maxWrite: 2}
	e := NewEngine(nil)
	e.conns[1] = ownedConn{profileID: "profile", conn: conn, network: "udp"}

	payload := []byte("abcd")
	if err := e.WriteDatagram(1, payload); err != io.ErrShortWrite {
		t.Fatalf("short datagram write error = %v, want ErrShortWrite", err)
	}

	conn.maxWrite = 0
	if err := e.WriteDatagram(1, payload); err != nil {
		t.Fatalf("WriteDatagram: %v", err)
	}
	if got := conn.writeData.Bytes(); !bytes.Equal(got, append([]byte("ab"), payload...)) {
		t.Fatalf("written datagrams = %q", got)
	}

	got, err := e.ReadDatagram(1)
	if err != io.EOF || string(got) != "pkt" {
		t.Fatalf("ReadDatagram = %q, %v; want payload and EOF", got, err)
	}
	if _, err := e.ReadDatagram(1); err != io.EOF {
		t.Fatalf("second ReadDatagram error = %v, want EOF", err)
	}
}

type noHalfCloseConn struct{}

func (c *noHalfCloseConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (c *noHalfCloseConn) Write(p []byte) (int, error)      { return len(p), nil }
func (c *noHalfCloseConn) Close() error                     { return nil }
func (c *noHalfCloseConn) LocalAddr() net.Addr              { return testAddr("local") }
func (c *noHalfCloseConn) RemoteAddr() net.Addr             { return testAddr("remote") }
func (c *noHalfCloseConn) SetDeadline(time.Time) error      { return nil }
func (c *noHalfCloseConn) SetReadDeadline(time.Time) error  { return nil }
func (c *noHalfCloseConn) SetWriteDeadline(time.Time) error { return nil }
