//go:build !windows

package disks

import (
	"context"
	"errors"
)

// List returns disks on Unix systems. Initial Windows-focused release —
// Linux and macOS implementations land as we add HITL for Sovol + Arco
// on those hosts.
func List(ctx context.Context) ([]DiskInfo, error) {
	return nil, errors.New("disks.list: not yet implemented on this platform")
}
