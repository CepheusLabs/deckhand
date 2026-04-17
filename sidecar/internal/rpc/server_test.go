package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

func TestServer_PingSuccess(t *testing.T) {
	s := NewServer()
	s.Register("ping", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return map[string]any{"pong": true}, nil
	})

	in := strings.NewReader(`{"jsonrpc":"2.0","id":"1","method":"ping","params":{}}` + "\n")
	out := &bytes.Buffer{}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = s.Serve(ctx, in, out) }()
	waitForLine(t, out)

	line := out.String()
	if !strings.Contains(line, `"pong":true`) {
		t.Fatalf("unexpected response: %q", line)
	}
	if !strings.Contains(line, `"id":"1"`) {
		t.Fatalf("response missing id correlation: %q", line)
	}
}

func TestServer_MethodNotFound(t *testing.T) {
	s := NewServer()
	in := strings.NewReader(`{"jsonrpc":"2.0","id":"1","method":"nope","params":{}}` + "\n")
	out := &bytes.Buffer{}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = s.Serve(ctx, in, out) }()
	waitForLine(t, out)

	line := out.String()
	if !strings.Contains(line, `"code":-32601`) {
		t.Fatalf("expected method-not-found error, got: %q", line)
	}
}

func TestServer_ParseError(t *testing.T) {
	s := NewServer()
	in := strings.NewReader("not-json" + "\n")
	out := &bytes.Buffer{}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = s.Serve(ctx, in, out) }()
	waitForLine(t, out)

	line := out.String()
	if !strings.Contains(line, `"code":-32700`) {
		t.Fatalf("expected parse error code, got: %q", line)
	}
}

func TestServer_Notification(t *testing.T) {
	s := NewServer()
	s.Register("long_op", func(ctx context.Context, _ json.RawMessage, note Notifier) (any, error) {
		note.Notify("progress", map[string]any{"percent": 50})
		return map[string]any{"done": true}, nil
	})

	in := strings.NewReader(`{"jsonrpc":"2.0","id":"op-123","method":"long_op","params":{}}` + "\n")
	out := &bytes.Buffer{}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() { _ = s.Serve(ctx, in, out) }()
	// Expect two lines: notification + response.
	waitForLines(t, out, 2)

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected 2 lines, got %d: %q", len(lines), out.String())
	}
	if !strings.Contains(lines[0], `"method":"progress"`) {
		t.Fatalf("first line should be notification, got: %q", lines[0])
	}
	if !strings.Contains(lines[0], `"operation_id":"op-123"`) {
		t.Fatalf("notification missing operation_id correlation: %q", lines[0])
	}
	if !strings.Contains(lines[1], `"done":true`) {
		t.Fatalf("second line should be response, got: %q", lines[1])
	}
}

// waitForLine waits up to a short window for at least one line to appear
// in the buffer; handy for the async serve loop in tests.
func waitForLine(t *testing.T, r io.Reader) {
	t.Helper()
	buf, ok := r.(*bytes.Buffer)
	if !ok {
		return
	}
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if strings.Contains(buf.String(), "\n") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no line written within deadline: %q", buf.String())
}

func waitForLines(t *testing.T, r io.Reader, n int) {
	t.Helper()
	buf, ok := r.(*bytes.Buffer)
	if !ok {
		return
	}
	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Count(buf.String(), "\n") >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected %d lines within deadline, got: %q", n, buf.String())
}
