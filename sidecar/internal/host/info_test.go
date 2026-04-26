package host

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestCurrent_SurfacesRuntimeMetadata pins the contract that the
// `host.info` JSON-RPC method exposes — the UI uses this to label
// crash reports and to know where the per-user data dir lives.
func TestCurrent_SurfacesRuntimeMetadata(t *testing.T) {
	got := Current()
	if got.OS != runtime.GOOS {
		t.Errorf("OS = %q, want %q", got.OS, runtime.GOOS)
	}
	if got.Arch != runtime.GOARCH {
		t.Errorf("Arch = %q, want %q", got.Arch, runtime.GOARCH)
	}
	if got.Home == "" {
		t.Errorf("Home is empty; expected os.UserHomeDir to resolve")
	}
	if got.Cache == "" {
		t.Errorf("Cache is empty; expected os.UserCacheDir to resolve")
	}
	if got.Data == "" {
		t.Errorf("Data is empty; expected os.UserConfigDir to resolve")
	}
}

func TestCurrent_SettingsPathLandsUnderDataDir(t *testing.T) {
	got := Current()
	// settings.json lives at <Data>/Deckhand/settings.json. We don't
	// pin the exact separator — filepath.Join handles that — but the
	// returned path must start with the data dir AND end with the
	// canonical filename. A regression that flipped these (e.g.
	// rooting the file under Cache) would land here.
	if !strings.HasPrefix(got.Settings, got.Data) {
		t.Fatalf("Settings %q is not under Data dir %q", got.Settings, got.Data)
	}
	if filepath.Base(got.Settings) != "settings.json" {
		t.Fatalf("Settings basename = %q, want settings.json", filepath.Base(got.Settings))
	}
	if !strings.Contains(got.Settings, "Deckhand") {
		t.Fatalf("Settings %q should be namespaced under a Deckhand dir", got.Settings)
	}
}

// TestCurrent_DeterministicAcrossCalls catches accidental
// statefulness. Current() reads only env-rooted helpers, so two
// calls in a row must agree.
func TestCurrent_DeterministicAcrossCalls(t *testing.T) {
	a, b := Current(), Current()
	if a != b {
		t.Fatalf("Current() not deterministic: a=%+v b=%+v", a, b)
	}
}
