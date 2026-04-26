package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/CepheusLabs/deckhand/sidecar/internal/handlers"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// TestRenderedMarkdown_ListsEveryRegisteredMethod is the unit-level
// smoke test: every method `handlers.Register` wires up must show
// up in the rendered markdown. Catches the typical regression
// (someone adds a new RPC and forgets to mention it in
// IPC-METHODS.md) without spawning a subprocess.
func TestRenderedMarkdown_ListsEveryRegisteredMethod(t *testing.T) {
	s := rpc.NewServer()
	_, cancel := context.WithCancel(context.Background())
	defer cancel()
	handlers.Register(s, cancel, "test")

	md := s.RenderMethodsMarkdown()
	want := []string{
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
	for _, w := range want {
		if !strings.Contains(md, w) {
			t.Errorf("rendered markdown is missing %s", w)
		}
	}
}

// TestCheckMode_DetectsDrift drives the --check binary against a
// staged docs file. Three scenarios:
//
//  1. fresh-generated file → exit 0
//  2. byte-mutated file    → exit 1
//  3. restored file         → exit 0
//
// Without this test, the drift gate could silently regress (e.g. a
// future "always pass" bug) without anyone noticing until a real
// drift slipped through.
func TestCheckMode_DetectsDrift(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping subprocess-driving test in -short mode")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skipf("go binary not on PATH: %v", err)
	}
	tmp := t.TempDir()
	docs := filepath.Join(tmp, "IPC-METHODS.md")

	// Resolve the package import path the same way `go run` does.
	// We run from this test's working directory, which `go test`
	// sets to the package source dir, so a relative import works.
	args := []string{"run", "."}

	mustRun := func(extra ...string) int {
		t.Helper()
		cmd := exec.Command("go", append(args, extra...)...) //nolint:gosec
		cmd.Stderr = os.Stderr
		if _, err := cmd.Output(); err != nil {
			if exit, ok := err.(*exec.ExitError); ok {
				return exit.ExitCode()
			}
			t.Fatalf("run %v: %v", extra, err)
		}
		return 0
	}

	// 1. Generate fresh.
	if ec := mustRun("-o", docs); ec != 0 {
		t.Fatalf("initial generate exited %d", ec)
	}
	// 2. --check against the freshly-generated file → 0.
	if ec := mustRun("-o", docs, "--check"); ec != 0 {
		t.Fatalf("check on fresh file exited %d, want 0", ec)
	}
	// 3. Mutate one byte → expect exit 1.
	body, err := os.ReadFile(docs)
	if err != nil {
		t.Fatalf("read fresh: %v", err)
	}
	if err := os.WriteFile(docs, append(body, []byte("\n<drift>\n")...), 0o644); err != nil {
		t.Fatalf("mutate: %v", err)
	}
	if ec := mustRun("-o", docs, "--check"); ec == 0 {
		t.Fatalf("check on drifted file exited 0, want non-zero")
	}
	// 4. Restore, check passes again.
	if err := os.WriteFile(docs, body, 0o644); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if ec := mustRun("-o", docs, "--check"); ec != 0 {
		t.Fatalf("check after restore exited %d, want 0", ec)
	}

	// Cross-platform sanity: filepath.Base resolves the same path
	// the production code writes to, regardless of OS.
	if filepath.Base(docs) != "IPC-METHODS.md" {
		t.Fatalf("docs base name = %q; runtime=%s", filepath.Base(docs), runtime.GOOS)
	}
}
