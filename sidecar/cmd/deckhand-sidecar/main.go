// Package main is the Deckhand sidecar entry point.
//
// The sidecar is a line-delimited JSON-RPC 2.0 server speaking over
// stdin/stdout. The Deckhand Flutter app spawns it as a child process at
// launch; it handles local disk I/O, sha256, shallow git clones, and
// HTTP fetches — operations Dart can't do portably without a lot of
// platform code.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// Version is set at build time via -ldflags "-X main.Version=..."
var Version = "0.0.0-dev"

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server := rpc.NewServer()
	registerHandlers(server)

	reader := bufio.NewReader(os.Stdin)
	writer := bufio.NewWriter(os.Stdout)

	fmt.Fprintf(os.Stderr, "[deckhand-sidecar] version=%s os=%s arch=%s pid=%d\n",
		Version, runtime.GOOS, runtime.GOARCH, os.Getpid())

	if err := server.Serve(ctx, reader, writer); err != nil {
		fmt.Fprintf(os.Stderr, "[deckhand-sidecar] serve error: %v\n", err)
		os.Exit(1)
	}
}

func registerHandlers(s *rpc.Server) {
	s.Register("ping", func(ctx context.Context, _ json.RawMessage) (any, error) {
		return map[string]any{
			"sidecar_version": Version,
			"os":              runtime.GOOS,
			"arch":            runtime.GOARCH,
		}, nil
	})

	s.Register("version.compat", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var req struct {
			UIVersion string `json:"ui_version"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		// Accept any UI version for now. Real compatibility matrix lands
		// with the first shipping release.
		return map[string]any{"compatible": true, "sidecar_version": Version}, nil
	})

	s.Register("host.info", func(ctx context.Context, _ json.RawMessage) (any, error) {
		home, _ := os.UserHomeDir()
		cache, _ := os.UserCacheDir()
		config, _ := os.UserConfigDir()
		return map[string]any{
			"os":        runtime.GOOS,
			"arch":      runtime.GOARCH,
			"home_dir":  home,
			"cache_dir": cache,
			"data_dir":  config,
		}, nil
	})

	s.Register("shutdown", func(ctx context.Context, _ json.RawMessage) (any, error) {
		go func() {
			// Let the current response flush before exiting.
			os.Exit(0)
		}()
		return map[string]any{"ok": true}, nil
	})

	// Real handler registrations (disks, os images, profiles, hash)
	// land in their respective internal packages.
}
