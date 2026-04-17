// Package disks handles local disk enumeration, image reads (backups),
// and image writes (flashes). Writes route through the elevated helper
// binary — the sidecar itself never runs with elevation.
package disks

// DiskInfo is the JSON-serializable shape returned by `disks.list`.
type DiskInfo struct {
	ID         string      `json:"id"`
	Path       string      `json:"path"`
	SizeBytes  int64       `json:"size_bytes"`
	Bus        string      `json:"bus"`
	Model      string      `json:"model"`
	Removable  bool        `json:"removable"`
	Partitions []Partition `json:"partitions"`
}

// Partition is one partition on a DiskInfo.
type Partition struct {
	Index      int    `json:"index"`
	Filesystem string `json:"filesystem,omitempty"`
	SizeBytes  int64  `json:"size_bytes"`
	Mountpoint string `json:"mountpoint,omitempty"`
}
