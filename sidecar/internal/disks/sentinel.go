package disks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// InterruptedFlash records that a flash to a given disk started but
// never completed. The Deckhand UI writes a sentinel file before
// launching the elevated helper and clears it after observing the
// helper's `event: done`. Any sentinel surviving past helper exit
// indicates a crash or power loss mid-write.
//
// The struct is attached to DiskInfo records so the UI's manage view
// and S200 flash-target screen can warn the user that the disk is in
// an unknown state.
type InterruptedFlash struct {
	StartedAt   time.Time `json:"started_at"`
	ImagePath   string    `json:"image_path"`
	ImageSHA256 string    `json:"image_sha256,omitempty"`
}

// SentinelStaleAfter caps how old a sentinel can be before disks.list
// stops surfacing it. A user who never returns to Deckhand after a
// failed flash shouldn't have a stale warning haunt every future
// disks.list call against a similarly-named device. Seven days is a
// human-friendly compromise between "we still remember" and "this is
// almost certainly historical."
const SentinelStaleAfter = 7 * 24 * time.Hour

// safeIDRe restricts disk IDs to a filename-safe character set when
// they're used to construct sentinel filenames. Anything outside this
// set is escape-encoded so a maliciously-crafted disk_id can't escape
// the sentinel directory via traversal or NUL.
var safeIDRe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// sentinelFile returns the canonical filename for a sentinel keyed by
// disk_id. Non-safe characters are percent-encoded so the round-trip
// disk_id ↔ filename is unambiguous and traversal-proof.
func sentinelFile(dir, diskID string) string {
	safe := safeIDRe.ReplaceAllStringFunc(diskID, func(match string) string {
		return fmt.Sprintf("_%02X", match[0])
	})
	return filepath.Join(dir, safe+".json")
}

// LoadSentinels scans dir for sentinel files and returns a map keyed
// by disk_id. Stale sentinels (older than SentinelStaleAfter) are
// silently ignored so the UI doesn't surface them.
//
// Errors reading individual files are swallowed: a corrupt or
// half-written sentinel is functionally indistinguishable from "no
// info" for the user's purposes, and we'd rather miss a sentinel than
// fail a disks.list call over one bad file.
func LoadSentinels(dir string) (map[string]InterruptedFlash, error) {
	out := make(map[string]InterruptedFlash)
	if dir == "" {
		return out, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return out, fmt.Errorf("read sentinel dir %q: %w", dir, err)
	}
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		var s sentinelOnDisk
		if err := json.Unmarshal(raw, &s); err != nil {
			continue
		}
		if s.DiskID == "" {
			continue
		}
		if time.Since(s.StartedAt) > SentinelStaleAfter {
			continue
		}
		out[s.DiskID] = InterruptedFlash{
			StartedAt:   s.StartedAt,
			ImagePath:   s.ImagePath,
			ImageSHA256: s.ImageSHA256,
		}
	}
	return out, nil
}

// AnnotateInterrupted overlays sentinel data onto a slice of DiskInfo.
// Disks without a matching sentinel are returned unchanged.
//
// Returned slice is a copy: callers can mutate without disturbing the
// listed records inside disks.List's cache (we don't have one today,
// but defensive copy keeps that option open).
func AnnotateInterrupted(disks []DiskInfo, sentinels map[string]InterruptedFlash) []DiskInfo {
	if len(sentinels) == 0 {
		return disks
	}
	out := make([]DiskInfo, len(disks))
	for i, d := range disks {
		out[i] = d
		if s, ok := sentinels[d.ID]; ok {
			s := s
			out[i].InterruptedFlash = &s
		}
	}
	return out
}

// sentinelOnDisk is the wire format for a sentinel file. Kept private
// so callers go through LoadSentinels rather than poking the layout
// directly.
type sentinelOnDisk struct {
	Schema      string    `json:"schema"`
	DiskID      string    `json:"disk_id"`
	StartedAt   time.Time `json:"started_at"`
	ImagePath   string    `json:"image_path"`
	ImageSHA256 string    `json:"image_sha256,omitempty"`
}
