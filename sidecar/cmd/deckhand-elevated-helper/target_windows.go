//go:build windows

package main

import "strings"

// targetToDevicePath normalizes a user-facing disk id (PhysicalDrive3)
// or bare path (\\.\PHYSICALDRIVE3) to a valid Windows device path.
func targetToDevicePath(target string) string {
	if strings.HasPrefix(target, `\\.\`) {
		return target
	}
	if strings.HasPrefix(strings.ToLower(target), "physicaldrive") {
		return `\\.\` + target
	}
	return target
}
