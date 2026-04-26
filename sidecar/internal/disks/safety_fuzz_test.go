package disks

import (
	"encoding/json"
	"testing"
)

// FuzzAssessWriteTarget throws arbitrary DiskInfo at the safety check.
// The guarantee we care about: the function must never panic, must
// always return a result, and a result with `Allowed: true` must
// never contain a BlockingReason.
//
// This catches bugs where a new blocking condition is added without
// the corresponding `res.Allowed = false` flip — the kind of
// regression that would let an oversized disk slip through the
// safety net despite a blocking reason being recorded.
func FuzzAssessWriteTarget(f *testing.F) {
	seeds := []string{
		`{"id":"emmcblk0","size_bytes":34359738368,"removable":true}`,
		`{"id":"nvme0n1","size_bytes":2199023255552,"removable":false}`,
		`{"id":"","size_bytes":0}`,
		`{"id":"sda","size_bytes":137438953472,"removable":true}`, // 128 GiB edge
		`{"id":"sda","size_bytes":549755813888,"removable":true}`, // 512 GiB edge
		`{"id":"sda","size_bytes":-1}`,                            // negative
		`{"id":"sda","size_bytes":1,"removable":true}`,            // tiny
		`{"id":"sda","size_bytes":16777216,"removable":true,"partitions":[{"index":1,"mountpoint":"/"}]}`,
		`{"id":"x","size_bytes":16777216,"removable":true,"partitions":[{"index":1,"mountpoint":"C:\\"}]}`,
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, raw string) {
		var info DiskInfo
		if err := json.Unmarshal([]byte(raw), &info); err != nil {
			t.Skip()
		}
		res := AssessWriteTarget(info)
		if res.Allowed && len(res.BlockingReasons) > 0 {
			t.Fatalf("Allowed=true but BlockingReasons=%v for input %q",
				res.BlockingReasons, raw)
		}
		if !res.Allowed && len(res.BlockingReasons) == 0 {
			t.Fatalf("Allowed=false but no BlockingReasons for input %q", raw)
		}
		if res.DiskID != info.ID {
			t.Fatalf("result disk_id %q does not match input %q",
				res.DiskID, info.ID)
		}
	})
}
