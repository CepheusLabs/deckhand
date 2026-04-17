//go:build !windows

package main

// targetToDevicePath is the Unix identity pass-through. Callers send the
// full /dev/... path.
func targetToDevicePath(target string) string {
	return target
}
