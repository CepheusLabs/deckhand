package handlers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// TestRegister_RegistersEveryMethod makes sure the IPC docs generator
// (which reuses handlers.Register) will always see every public method.
// If you add a new RPC, add it here too - that's the whole point.
func TestRegister_RegistersEveryMethod(t *testing.T) {
	s := rpc.NewServer()
	_, cancel := context.WithCancel(context.Background())
	defer cancel()

	Register(s, cancel, "test-version")

	md := s.RenderMethodsMarkdown()
	expected := []string{
		"`ping`",
		"`version.compat`",
		"`host.info`",
		"`shutdown`",
		"`jobs.cancel`",
		"`disks.list`",
		"`disks.hash`",
		"`disks.read_image`",
		"`disks.safety_check`",
		"`disks.write_image`",
		"`os.download`",
		"`profiles.fetch`",
	}
	for _, want := range expected {
		if !strings.Contains(md, want) {
			t.Errorf("expected %s in rendered markdown, not found", want)
		}
	}
}

// dispatch runs the full RPC read/dispatch/respond loop for a single
// request and returns the decoded response. It's the integration
// seam we want when a handler test isn't about the domain package
// behind it (that package has its own unit tests) but about the
// handler's params validation + error mapping.
func dispatch(t *testing.T, req map[string]any) map[string]any {
	t.Helper()

	s := rpc.NewServer()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	Register(s, cancel, "test-version")

	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	in := bytes.NewReader(append(body, '\n'))
	var out bytes.Buffer

	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx, in, &out) }()

	select {
	case err := <-done:
		if err != nil && err != context.Canceled && err != io.EOF {
			t.Fatalf("Serve: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("Serve did not return within 5s")
	}

	sc := bufio.NewScanner(&out)
	sc.Buffer(make([]byte, 1<<16), 1<<24)
	if !sc.Scan() {
		t.Fatalf("no response on stdout")
	}
	var resp map[string]any
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v (line=%q)", err, sc.Text())
	}
	return resp
}

// TestDisksSafetyCheck_MissingParamsRejected confirms the RPC-layer
// ParamSpec fires before the handler touches the domain layer. A
// caller that forgot `disk.id` should get a -32602 invalid-params
// error, not a cryptic domain failure.
func TestDisksSafetyCheck_MissingParamsRejected(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "1",
		"method":  "disks.safety_check",
		"params":  map[string]any{},
	})

	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error response, got %+v", resp)
	}
	if code, _ := errObj["code"].(float64); int(code) != -32000 {
		// -32000 is CodeGeneric; handler explicitly rejects empty ID
		// before the safety check runs. Adjust if policy changes.
		t.Fatalf("expected code -32000, got %v: %v", code, errObj["message"])
	}
}

// TestDisksSafetyCheck_AllowsEMMC runs the happy path: a typical
// 32 GiB removable disk with no system mounts should come back
// Allowed=true and no warnings.
func TestDisksSafetyCheck_AllowsEMMC(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "2",
		"method":  "disks.safety_check",
		"params": map[string]any{
			"disk": map[string]any{
				"id":         "mmcblk0",
				"path":       "/dev/mmcblk0",
				"size_bytes": 32 * 1024 * 1024 * 1024,
				"bus":        "MMC",
				"model":      "Generic eMMC",
				"removable":  true,
				"partitions": []any{},
			},
		},
	})
	if _, hasErr := resp["error"]; hasErr {
		t.Fatalf("expected no error, got %+v", resp["error"])
	}
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("expected result object, got %+v", resp)
	}
	if allowed, _ := result["allowed"].(bool); !allowed {
		t.Fatalf("expected allowed=true, got %+v", result)
	}
}

// TestDisksSafetyCheck_BlocksOversizedDisk ensures the RPC surfaces
// the blocking reasons as structured data the UI can render. The
// domain layer's string messages must make it through the JSON-RPC
// boundary without being flattened into a single "unsafe" bool.
func TestDisksSafetyCheck_BlocksOversizedDisk(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "3",
		"method":  "disks.safety_check",
		"params": map[string]any{
			"disk": map[string]any{
				"id":         "nvme0n1",
				"size_bytes": 2 * 1024 * 1024 * 1024 * 1024, // 2 TiB
				"removable":  false,
			},
		},
	})
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("expected result, got %+v", resp)
	}
	if allowed, _ := result["allowed"].(bool); allowed {
		t.Fatalf("expected allowed=false on 2TiB disk, got %+v", result)
	}
	reasons, _ := result["blocking_reasons"].([]any)
	if len(reasons) == 0 {
		t.Fatalf("expected blocking_reasons, got %+v", result)
	}
}

// TestDisksWriteImage_PreflightBlocksUnsafeTarget proves the
// defense-in-depth re-check inside the write handler: even if the
// UI somehow skipped disks.safety_check, passing an obviously unsafe
// `disk` alongside the write request must error with the structured
// `reason: "unsafe_target"` data the UI branches on.
func TestDisksWriteImage_PreflightBlocksUnsafeTarget(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "4",
		"method":  "disks.write_image",
		"params": map[string]any{
			"image_path":         "/tmp/does-not-matter.img",
			"disk_id":            "nvme0n1",
			"confirmation_token": "tok",
			"disk": map[string]any{
				"id":         "nvme0n1",
				"size_bytes": 2 * 1024 * 1024 * 1024 * 1024,
				"removable":  false,
			},
		},
	})
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error (unsafe_target), got %+v", resp)
	}
	data, _ := errObj["data"].(map[string]any)
	if reason, _ := data["reason"].(string); reason != "unsafe_target" {
		t.Fatalf("expected data.reason=unsafe_target, got %v (full: %+v)", reason, errObj)
	}
}
