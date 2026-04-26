// Package handlers wires every JSON-RPC method the Deckhand sidecar
// exposes onto an rpc.Server. It lives in its own package (rather than
// inline in cmd/deckhand-sidecar) so the IPC docs generator at
// cmd/deckhand-ipc-docs can import and replay the same registration
// set - main packages are not importable in Go.
package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/doctor"
	"github.com/CepheusLabs/deckhand/sidecar/internal/hash"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
	"github.com/CepheusLabs/deckhand/sidecar/internal/profiles"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// Register wires every handler onto s. The cancel parameter is the
// outer Serve context's cancel func; `shutdown` calls it so the Serve
// loop exits cleanly. version is used by `ping` and `version.compat`.
func Register(s *rpc.Server, cancel context.CancelFunc, version string) {
	// Lifecycle
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "ping",
		Description: "Liveness + version probe. Returns sidecar version and host os/arch.",
		Returns:     "{sidecar_version, os, arch}",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			return map[string]any{
				"sidecar_version": version,
				"os":              runtime.GOOS,
				"arch":            runtime.GOARCH,
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "version.compat",
		Description: "Report whether the UI's version is compatible with this sidecar.",
		Params: []rpc.ParamSpec{
			{Name: "ui_version", Kind: rpc.ParamKindString, MaxLen: 64},
		},
		Returns: "{compatible, sidecar_version, ui_version}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			var req struct {
				UIVersion string `json:"ui_version"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, fmt.Errorf("decode params: %w", err)
			}
			// Today the contract is simple: there is one sidecar version
			// and it accepts every UI that speaks JSON-RPC 2.0 on our
			// method surface. When we introduce breaking changes we'll
			// switch this to real comparison - for now we honestly report
			// "compatible" plus the UI version we saw so a bug report can
			// include both.
			return map[string]any{
				"compatible":      true,
				"sidecar_version": version,
				"ui_version":      req.UIVersion,
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "host.info",
		Description: "Return host platform info plus Deckhand's data/cache/settings paths.",
		Returns:     "host.Info",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			return host.Current(), nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "doctor.run",
		Description: "Run the sidecar self-diagnostic and return structured results.",
		Returns:     "{passed: bool, results: [{name, status, detail}], report: string}",
		Handler: func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			results := doctor.Collect(ctx, version)
			passed := true
			out := make([]map[string]string, 0, len(results))
			for _, r := range results {
				if r.Status == doctor.StatusFail {
					passed = false
				}
				out = append(out, map[string]string{
					"name":   r.Name,
					"status": string(r.Status),
					"detail": r.Detail,
				})
			}
			// Also include the CLI-style human-readable report so the
			// UI's "View report" button can show identical output to
			// the bundled `deckhand-sidecar doctor` command. Render
			// from the already-collected slice rather than calling
			// doctor.Run a second time (which would re-run every
			// check and double the wall time of doctor.run).
			var buf bytes.Buffer
			for _, r := range results {
				_, _ = fmt.Fprintf(&buf, "[%s] %s — %s\n", r.Status, r.Name, r.Detail)
			}
			summary := "all checks passed"
			if !passed {
				summary = "one or more blocking issues found"
			}
			_, _ = fmt.Fprintf(&buf, "\n%s\n", summary)
			return map[string]any{
				"passed":  passed,
				"results": out,
				"report":  buf.String(),
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "shutdown",
		Description: "Ask the sidecar to drain in-flight handlers and exit.",
		Returns:     "{ok}",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			// Cancel the Serve context so the loop exits naturally after
			// the response is flushed to stdout. This avoids the data
			// race the earlier `go os.Exit(0)` had with the response
			// write, and lets in-flight handlers finish (or respond to
			// ctx cancellation) instead of being hard-killed mid-
			// download.
			cancel()
			return map[string]any{"ok": true}, nil
		},
	})

	// jobs.cancel - cancel a single in-flight operation by its request id.
	jobsCancelSpecs := []rpc.ParamSpec{
		{Name: "id", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 256},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "jobs.cancel",
		Description: "Cancel an in-flight handler by its originating JSON-RPC id.",
		Params:      jobsCancelSpecs,
		Returns:     "{ok, cancelled}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, jobsCancelSpecs); err != nil {
				return nil, err
			}
			var req struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			return map[string]any{
				"ok":        true,
				"cancelled": s.CancelJob(req.ID),
			}, nil
		},
	})

	// Disks
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.list",
		Description: "Enumerate writable disks attached to the host.",
		Returns:     "{disks: DiskInfo[]}",
		Handler: func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			infos, err := disks.List(ctx)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "disks.list failed: %v", err)
			}
			// Annotate with any interrupted-flash sentinels left over
			// from a prior write that didn't reach `event: done`. A
			// sentinel-read failure is non-fatal — disks.list must
			// always succeed if the underlying enumeration did, even
			// if the sentinel directory is corrupt or unreadable.
			sentinels, _ := disks.LoadSentinels(sentinelDir())
			infos = disks.AnnotateInterrupted(infos, sentinels)
			return map[string]any{"disks": infos}, nil
		},
	})

	disksHashSpecs := []rpc.ParamSpec{
		{Name: "path", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.hash",
		Description: "SHA-256 of a file at a Deckhand-managed path (downloads or device nodes).",
		Params:      disksHashSpecs,
		Returns:     "{sha256, path}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, disksHashSpecs); err != nil {
				return nil, err
			}
			var req struct {
				Path string `json:"path"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			// disks.hash is intended for image files Deckhand itself wrote
			// or downloaded (post-download verification), not arbitrary
			// paths. Enforce a safe subset to keep this from being a
			// generic "read file existence/contents" oracle.
			if err := validateHashPath(req.Path); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			h, err := hash.SHA256(req.Path)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "hash failed: %v", err)
			}
			return map[string]any{"sha256": h, "path": req.Path}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.read_image",
		Description: "Read a raw device to a local file with progress notifications.",
		Params: []rpc.ParamSpec{
			{Name: "device_id", Kind: rpc.ParamKindString, MaxLen: 256},
			{Name: "path", Kind: rpc.ParamKindString, MaxLen: 4096},
			{Name: "output", Kind: rpc.ParamKindString, MaxLen: 4096},
		},
		Returns: "{sha256, output}",
		Handler: func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
			var req struct {
				DeviceID string `json:"device_id"`
				Path     string `json:"path"`
				Output   string `json:"output"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			dev, err := disks.ResolveDevicePath(req.Path, req.DeviceID)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "resolve device: %v", err)
			}
			sha, err := disks.ReadImage(ctx, dev, req.Output, note)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "read_image: %v", err)
			}
			return map[string]any{"sha256": sha, "output": req.Output}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.safety_check",
		Description: "Assess whether a target disk is safe to write. Returns a verdict.",
		Params: []rpc.ParamSpec{
			{Name: "disk", Required: true, Kind: rpc.ParamKindObject},
		},
		Returns: "SafetyVerdict",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			var req struct {
				Disk disks.DiskInfo `json:"disk"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			if req.Disk.ID == "" {
				return nil, rpc.NewError(rpc.CodeGeneric, "disk.id is required")
			}
			return disks.AssessWriteTarget(req.Disk), nil
		},
	})

	writeImageSpecs := []rpc.ParamSpec{
		{Name: "image_path", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "disk_id", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 256},
		{Name: "confirmation_token", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 512},
		{Name: "disk", Kind: rpc.ParamKindObject},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.write_image",
		Description: "Write a local image to a disk. Requires a confirmation_token issued by the UI.",
		Params:      writeImageSpecs,
		Returns:     "{ok} or rpc.Error with reason elevation_required / unsafe_target",
		Handler: func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, writeImageSpecs); err != nil {
				return nil, err
			}
			var req struct {
				ImagePath         string          `json:"image_path"`
				DiskID            string          `json:"disk_id"`
				ConfirmationToken string          `json:"confirmation_token"`
				Disk              *disks.DiskInfo `json:"disk"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			// Defense-in-depth preflight. If the UI passes the DiskInfo
			// alongside the write request, we re-run the safety check
			// here before telling the caller to elevate - this catches
			// a malicious or racy UI that skipped the separate safety
			// call.
			if req.Disk != nil {
				verdict := disks.AssessWriteTarget(*req.Disk)
				if !verdict.Allowed {
					return nil, &rpc.Error{
						Code:    rpc.CodeDisk + 2,
						Message: "safety check refused this target",
						Data: map[string]any{
							"reason":  "unsafe_target",
							"verdict": verdict,
						},
					}
				}
			}
			if err := disks.WriteImage(ctx, req.ImagePath, req.DiskID, req.ConfirmationToken); err != nil {
				if errors.Is(err, disks.ErrElevationRequired) {
					// Domain-specific code so the UI can branch to an
					// elevation prompt rather than treating this as a
					// generic failure.
					return nil, &rpc.Error{
						Code:    rpc.CodeDisk + 1,
						Message: err.Error(),
						Data:    map[string]any{"reason": "elevation_required"},
					}
				}
				return nil, rpc.NewError(rpc.CodeDisk, "write_image: %v", err)
			}
			return map[string]any{"ok": true}, nil
		},
	})

	// OS image download
	downloadSpecs := []rpc.ParamSpec{
		{Name: "url", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096, Pattern: `^https?://`},
		{Name: "dest", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "sha256", Kind: rpc.ParamKindString, MaxLen: 128},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "os.download",
		Description: "Download an OS image to dest, optionally verifying the expected SHA-256.",
		Params:      downloadSpecs,
		Returns:     "{sha256, path}",
		Handler: func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, downloadSpecs); err != nil {
				return nil, err
			}
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
		},
	})

	// Profile fetch (go-git shallow clone, optional signed-tag verify)
	profilesFetchSpecs := []rpc.ParamSpec{
		{Name: "repo_url", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 2048},
		{Name: "ref", Kind: rpc.ParamKindString, MaxLen: 256},
		{Name: "dest", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "force", Kind: rpc.ParamKindBool},
		{Name: "trusted_keys", Kind: rpc.ParamKindString},
		{Name: "require_signed_tag", Kind: rpc.ParamKindBool},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "profiles.fetch",
		Description: "Shallow-clone a Klipper config profile repo; optionally verify a signed tag.",
		Params:      profilesFetchSpecs,
		Returns:     "profiles.FetchResult",
		Handler: func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, profilesFetchSpecs); err != nil {
				return nil, err
			}
			var req struct {
				RepoURL          string `json:"repo_url"`
				Ref              string `json:"ref"`
				Dest             string `json:"dest"`
				Force            bool   `json:"force"`
				TrustedKeys      string `json:"trusted_keys"`       // armored PGP keyring
				RequireSignedTag bool   `json:"require_signed_tag"` // reject unsigned/branch
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, fmt.Errorf("decode params: %w", err)
			}
			if err := validateRepoURL(req.RepoURL); err != nil {
				return nil, err
			}
			if err := validateGitRef(req.Ref); err != nil {
				return nil, err
			}
			opts := profiles.Options{
				RequireSignedTag: req.RequireSignedTag,
			}
			if req.TrustedKeys != "" {
				opts.TrustedKeys = []byte(req.TrustedKeys)
			}
			res, err := profiles.FetchWithOptions(ctx, req.RepoURL, req.Ref, req.Dest, req.Force, opts)
			if err != nil {
				if errors.Is(err, profiles.ErrUnsignedOrUntrusted) {
					return nil, &rpc.Error{
						Code:    rpc.CodeProfile + 1,
						Message: err.Error(),
						Data:    map[string]any{"reason": "unsigned_or_untrusted"},
					}
				}
				return nil, rpc.NewError(rpc.CodeProfile, "fetch: %v", err)
			}
			return res, nil
		},
	})
}

// sentinelDir returns the per-user directory the UI uses to record
// in-flight flash operations. It lives under the data dir from
// host.Current() so it follows the same per-OS convention as every
// other Deckhand state file. A best-effort read: returning "" when
// host.Current() can't resolve a data dir means LoadSentinels will
// silently return an empty map and disks.list still works.
func sentinelDir() string {
	info := host.Current()
	if info.Data == "" {
		return ""
	}
	return filepath.Join(info.Data, "Deckhand", "state", "flash-sentinels")
}

// validateHashPath restricts disks.hash to paths that plausibly belong
// to the set of files Deckhand itself manages - either raw block
// devices (when the UI is pre-flight checking a disk) or regular files
// under the sidecar's host-info download directory. Arbitrary
// filesystem paths are rejected so this RPC cannot be used as a
// "does-file-X-exist / hash-arbitrary-file" oracle.
func validateHashPath(p string) error {
	if p == "" {
		return fmt.Errorf("path is required")
	}
	clean := filepath.Clean(p)
	if strings.Contains(clean, "..") {
		return fmt.Errorf("path %q contains traversal", p)
	}
	// Raw-disk paths we use across OSes. These mirror the elevated
	// helper's allowlist (keep them in sync if one changes).
	devicePrefixes := []string{
		"/dev/sd", "/dev/nvme", "/dev/mmcblk", "/dev/disk",
		"/dev/rdisk", "/dev/loop", "/dev/vd",
	}
	for _, prefix := range devicePrefixes {
		if strings.HasPrefix(clean, prefix) && len(clean) > len(prefix) {
			return nil
		}
	}
	if runtime.GOOS == "windows" &&
		(strings.HasPrefix(clean, `\\.\`) || strings.HasPrefix(clean, `//./`)) {
		return nil
	}
	// Regular-file downloads under the sidecar's managed cache/data dirs.
	h := host.Current()
	for _, root := range []string{h.Cache, h.Data} {
		if root == "" {
			continue
		}
		cleanRoot := filepath.Clean(root)
		// Require a path separator after the root to prevent `/var/dataEVIL`
		// from matching `/var/data`.
		if strings.HasPrefix(clean, cleanRoot+string(os.PathSeparator)) {
			return nil
		}
	}
	// The system tmp dir is also acceptable for short-lived downloads
	// the UI stages before verification - TempDir is caller-controlled
	// by the OS, not attacker-controlled.
	tmp := filepath.Clean(os.TempDir())
	if tmp != "" && strings.HasPrefix(clean, tmp+string(os.PathSeparator)) {
		return nil
	}
	return fmt.Errorf("path %q is not under a Deckhand-managed directory or a recognised device node", p)
}

func validateRepoURL(raw string) error {
	if raw == "" {
		return fmt.Errorf("repo_url is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("parse repo_url %q: %w", raw, err)
	}
	if u.Scheme != "https" && u.Scheme != "http" {
		return fmt.Errorf("repo_url scheme must be http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("repo_url %q has no host", raw)
	}
	return nil
}

func validateGitRef(ref string) error {
	if ref == "" {
		// Empty ref = use the remote's default branch, which go-git
		// resolves for us. That's fine.
		return nil
	}
	for _, r := range ref {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '.' || r == '_' || r == '-' || r == '/':
			// allowed
		default:
			return fmt.Errorf("git ref %q contains disallowed character %q", ref, r)
		}
	}
	// No leading `-` (would look like a flag if ever spawned as a CLI
	// arg later), no `..` (ambiguous in ref syntax).
	if strings.HasPrefix(ref, "-") || strings.Contains(ref, "..") {
		return fmt.Errorf("git ref %q uses a disallowed sequence", ref)
	}
	return nil
}
