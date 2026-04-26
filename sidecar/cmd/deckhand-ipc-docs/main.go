// Package main generates docs/IPC-METHODS.md by booting the sidecar's
// handler registration under a throwaway rpc.Server and rendering its
// MethodSpec table as markdown.
//
// Usage:
//
//	go run ./cmd/deckhand-ipc-docs           # writes ../../docs/IPC-METHODS.md
//	go run ./cmd/deckhand-ipc-docs -o file   # writes to a specific path
//	go run ./cmd/deckhand-ipc-docs --check   # non-zero exit if file is stale
//
// Wire this into CI so the markdown stays in lockstep with the code.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/CepheusLabs/deckhand/sidecar/internal/handlers"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

func main() {
	var (
		outPath = flag.String("o", "", "output path; default ../../docs/IPC-METHODS.md relative to this package")
		check   = flag.Bool("check", false, "exit 1 if the current file does not match generated output")
	)
	flag.Parse()

	s := rpc.NewServer()
	// shutdown's cancel func is irrelevant here - we never Serve.
	_, cancel := context.WithCancel(context.Background())
	defer cancel()

	handlers.Register(s, cancel, "docs-generator")

	markdown := s.RenderMethodsMarkdown()

	target := *outPath
	if target == "" {
		target = defaultDocsPath()
	}

	if *check {
		existing, err := os.ReadFile(target) //nolint:gosec // target is CLI-controlled
		if err != nil {
			fmt.Fprintf(os.Stderr, "read %s: %v\n", target, err)
			os.Exit(1)
		}
		if !bytes.Equal(existing, []byte(markdown)) {
			fmt.Fprintf(os.Stderr, "%s is stale; regenerate with `go run ./cmd/deckhand-ipc-docs`\n", target)
			os.Exit(1)
		}
		return
	}

	if err := os.MkdirAll(filepath.Dir(target), 0o750); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir %s: %v\n", filepath.Dir(target), err)
		os.Exit(1)
	}
	if err := os.WriteFile(target, []byte(markdown), 0o644); err != nil { //nolint:gosec // docs file, not a secret
		fmt.Fprintf(os.Stderr, "write %s: %v\n", target, err)
		os.Exit(1)
	}
	if _, err := fmt.Fprintf(os.Stdout, "wrote %s (%d bytes)\n", target, len(markdown)); err != nil {
		// Stdout failures are extremely rare (closed pipe). Surface
		// the failure code so a CI step that pipes our output sees a
		// non-zero exit instead of silently dropping the message.
		os.Exit(2)
	}
}

// defaultDocsPath resolves ../../docs/IPC-METHODS.md from the generator's
// working directory. The sidecar is usually invoked from
// deckhand/sidecar, and docs live at deckhand/docs.
func defaultDocsPath() string {
	// Walk up from cwd until we find a dir that has both `sidecar` and
	// `docs` children - that's the deckhand/ root.
	wd, err := os.Getwd()
	if err != nil {
		return filepath.Join("docs", "IPC-METHODS.md")
	}
	cur := wd
	for i := 0; i < 6; i++ {
		if stat, err := os.Stat(filepath.Join(cur, "sidecar")); err == nil && stat.IsDir() {
			if stat2, err := os.Stat(filepath.Join(cur, "docs")); err == nil && stat2.IsDir() {
				return filepath.Join(cur, "docs", "IPC-METHODS.md")
			}
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	// Fall back to a local docs/ next to the working directory.
	return filepath.Join(wd, "docs", "IPC-METHODS.md")
}
