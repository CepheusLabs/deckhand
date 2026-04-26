package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestJobRegistry_RegisterAndCancel(t *testing.T) {
	r := newJobRegistry()
	ctx, cancel := context.WithCancel(context.Background())
	release := r.register("op-1", cancel)
	defer release()

	if r.active() != 1 {
		t.Fatalf("expected 1 active job, got %d", r.active())
	}

	if !r.cancel("op-1") {
		t.Fatalf("expected cancel to report found")
	}
	select {
	case <-ctx.Done():
	case <-time.After(500 * time.Millisecond):
		t.Fatalf("context was not cancelled")
	}
}

func TestJobRegistry_ReleaseRemovesEntry(t *testing.T) {
	r := newJobRegistry()
	_, cancel := context.WithCancel(context.Background())
	release := r.register("op-1", cancel)

	release()
	if r.active() != 0 {
		t.Fatalf("expected 0 active jobs after release, got %d", r.active())
	}
	if r.cancel("op-1") {
		t.Fatalf("expected cancel on released job to return false")
	}
}

func TestJobRegistry_DuplicateIDReplaces(t *testing.T) {
	r := newJobRegistry()
	_, cancel1 := context.WithCancel(context.Background())
	_, cancel2 := context.WithCancel(context.Background())

	release1 := r.register("op-1", cancel1)
	release2 := r.register("op-1", cancel2)
	defer release1()
	defer release2()

	if r.active() != 1 {
		t.Fatalf("expected 1 active job, got %d", r.active())
	}
}

// End-to-end: slow handler observes ctx.Done when jobs.cancel fires.
func TestServer_JobsCancel_InterruptsSlowHandler(t *testing.T) {
	s := NewServer()
	done := make(chan error, 1)
	started := make(chan struct{})

	s.Register("slow", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		close(started)
		select {
		case <-ctx.Done():
			done <- ctx.Err()
			return nil, ctx.Err()
		case <-time.After(5 * time.Second):
			done <- nil
			return "ok", nil
		}
	})

	// Wire jobs.cancel the same way the real main.go will.
	s.Register("jobs.cancel", func(_ context.Context, raw json.RawMessage, _ Notifier) (any, error) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "cancelled": s.CancelJob(req.ID)}, nil
	})

	input := `{"jsonrpc":"2.0","id":"slow-1","method":"slow","params":{}}` + "\n"
	// The cancel line arrives on the same stream; Serve's read loop
	// dispatches it in a separate goroutine.
	input += `{"jsonrpc":"2.0","id":"cancel-1","method":"jobs.cancel","params":{"id":"slow-1"}}` + "\n"

	scanner, stop := driveServer(t, s, input)
	defer stop()

	// Wait for the slow handler to actually start so the cancel has
	// something to target.
	select {
	case <-started:
	case <-time.After(1 * time.Second):
		t.Fatalf("slow handler never started")
	}

	// We expect two responses (order not guaranteed): the cancel one
	// with cancelled:true, and the slow one with a context-cancelled
	// error.
	var sawCancelAck, sawSlowErr bool
	for i := 0; i < 2; i++ {
		line := readLine(t, scanner)
		switch {
		case strings.Contains(line, `"id":"cancel-1"`):
			if !strings.Contains(line, `"cancelled":true`) {
				t.Fatalf("cancel ack missing cancelled:true, got: %q", line)
			}
			sawCancelAck = true
		case strings.Contains(line, `"id":"slow-1"`):
			if !strings.Contains(line, "context canceled") {
				t.Fatalf("slow response should report cancellation, got: %q", line)
			}
			sawSlowErr = true
		default:
			t.Fatalf("unexpected line: %q", line)
		}
	}
	if !sawCancelAck || !sawSlowErr {
		t.Fatalf("missing responses: cancelAck=%v slowErr=%v", sawCancelAck, sawSlowErr)
	}

	// And the handler must have seen ctx.Done with context.Canceled.
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(1 * time.Second):
		t.Fatalf("handler did not observe ctx.Done in time")
	}
}

func TestServer_JobsCancel_UnknownID(t *testing.T) {
	s := NewServer()
	s.Register("jobs.cancel", func(_ context.Context, raw json.RawMessage, _ Notifier) (any, error) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "cancelled": s.CancelJob(req.ID)}, nil
	})

	scanner, stop := driveServer(t, s,
		`{"jsonrpc":"2.0","id":"1","method":"jobs.cancel","params":{"id":"nope"}}`+"\n")
	defer stop()
	line := readLine(t, scanner)
	if !strings.Contains(line, `"cancelled":false`) {
		t.Fatalf("expected cancelled:false for unknown id, got: %q", line)
	}
}
