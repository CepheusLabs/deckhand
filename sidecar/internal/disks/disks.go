// Package disks implements platform-specific disk enumeration and
// image read/write. Actual implementations land per-OS:
//
//   - disks_windows.go — \\.\PHYSICALDRIVE*, CreateFile, DeviceIoControl
//   - disks_linux.go   — /dev/sd*, /sys/block, ioctl
//   - disks_darwin.go  — /dev/diskN, diskutil, DiskArbitration
package disks

import "context"

// DiskInfo matches the JSON shape returned by `disks.list`.
type DiskInfo struct {
	ID         string      `json:"id"`
	Path       string      `json:"path"`
	SizeBytes  int64       `json:"size_bytes"`
	Bus        string      `json:"bus"`
	Model      string      `json:"model"`
	Removable  bool        `json:"removable"`
	Partitions []Partition `json:"partitions"`
}

type Partition struct {
	Index      int    `json:"index"`
	Filesystem string `json:"filesystem"`
	SizeBytes  int64  `json:"size_bytes"`
	Mountpoint string `json:"mountpoint,omitempty"`
}

// List enumerates local disks. Implemented per-platform; this stub keeps
// the package buildable cross-platform until the OS-specific files land.
func List(ctx context.Context) ([]DiskInfo, error) {
	return nil, errNotImplemented
}

// WriteImage streams bytes from [imagePath] onto the disk [diskID].
// Requires the `deckhand-elevated-helper` binary for actual writes.
func WriteImage(ctx context.Context, imagePath, diskID, confirmationToken string) error {
	return errNotImplemented
}

// ReadImage dds [diskID] into [outputPath].
func ReadImage(ctx context.Context, diskID, outputPath string) error {
	return errNotImplemented
}
