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

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/hash"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
	"github.com/CepheusLabs/deckhand/sidecar/internal/profiles"
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
	// Lifecycle
	s.Register("ping", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		return map[string]any{
			"sidecar_version": Version,
			"os":              runtime.GOOS,
			"arch":            runtime.GOARCH,
		}, nil
	})

	s.Register("version.compat", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			UIVersion string `json:"ui_version"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		return map[string]any{"compatible": true, "sidecar_version": Version}, nil
	})

	s.Register("host.info", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		return host.Current(), nil
	})

	s.Register("shutdown", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		go func() { os.Exit(0) }()
		return map[string]any{"ok": true}, nil
	})

	// Disks
	s.Register("disks.list", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		infos, err := disks.List(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"disks": infos}, nil
	})

	s.Register("disks.hash", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		h, err := hash.SHA256(req.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": h, "path": req.Path}, nil
	})

	s.Register("disks.read_image", func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
		var req struct {
			DeviceID string `json:"device_id"`
			Path     string `json:"path"`
			Output   string `json:"output"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		dev := req.Path
		if dev == "" {
			dev = `\\.\` + req.DeviceID
		}
		sha, err := disks.ReadImage(ctx, dev, req.Output, note)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": sha, "output": req.Output}, nil
	})

	s.Register("disks.write_image", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			ImagePath         string `json:"image_path"`
			DiskID            string `json:"disk_id"`
			ConfirmationToken string `json:"confirmation_token"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		if err := disks.WriteImage(ctx, req.ImagePath, req.DiskID, req.ConfirmationToken); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	})

	// OS image download
	s.Register("os.download", func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
		var req struct {
			URL         string `json:"url"`
			Dest        string `json:"dest"`
			ExpectedSha string `json:"sha256"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		sha, err := osimg.Download(ctx, req.URL, req.Dest, req.ExpectedSha, note)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": sha, "path": req.Dest}, nil
	})

	// Profile fetch (go-git shallow clone)
	s.Register("profiles.fetch", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			RepoURL string `json:"repo_url"`
			Ref     string `json:"ref"`
			Dest    string `json:"dest"`
			Force   bool   `json:"force"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		res, err := profiles.Fetch(ctx, req.RepoURL, req.Ref, req.Dest, req.Force)
		if err != nil {
			return nil, err
		}
		return res, nil
	})
}
