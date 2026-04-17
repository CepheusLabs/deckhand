// Package host exposes small host-platform helpers the rest of the
// sidecar calls into.
package host

import (
	"os"
	"path/filepath"
	"runtime"
)

// Info is the struct returned by the `host.info` JSON-RPC call.
type Info struct {
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	Home     string `json:"home_dir"`
	Cache    string `json:"cache_dir"`
	Data     string `json:"data_dir"`
	Settings string `json:"settings_file"`
}

// Current returns a best-effort Info for the running process.
func Current() Info {
	home, _ := os.UserHomeDir()
	cache, _ := os.UserCacheDir()
	config, _ := os.UserConfigDir()
	return Info{
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		Home:     home,
		Cache:    cache,
		Data:     config,
		Settings: filepath.Join(config, "Deckhand", "settings.json"),
	}
}
