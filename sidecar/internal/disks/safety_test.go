package disks

import (
	"runtime"
	"testing"
)

func TestAssessWriteTarget_AcceptsTypicalEMMC(t *testing.T) {
	d := DiskInfo{
		ID:        "emmcblk0",
		Path:      "/dev/mmcblk0",
		SizeBytes: 32 * 1024 * 1024 * 1024, // 32 GiB eMMC
		Bus:       "mmc",
		Model:     "Generic",
		Removable: true,
	}
	got := AssessWriteTarget(d)
	if !got.Allowed {
		t.Fatalf("expected allowed; blocking=%v", got.BlockingReasons)
	}
	if len(got.Warnings) != 0 {
		t.Fatalf("expected no warnings; got %v", got.Warnings)
	}
}

func TestAssessWriteTarget_BlocksOversizedDisk(t *testing.T) {
	d := DiskInfo{
		ID:        "nvme0n1",
		SizeBytes: 2 * 1024 * 1024 * 1024 * 1024, // 2 TiB
		Removable: false,
	}
	got := AssessWriteTarget(d)
	if got.Allowed {
		t.Fatalf("expected disallowed for a 2TiB non-removable disk")
	}
	if len(got.BlockingReasons) == 0 {
		t.Fatalf("expected blocking reasons")
	}
}

func TestAssessWriteTarget_WarnsOnLargeRemovable(t *testing.T) {
	d := DiskInfo{
		ID:        "sdb",
		SizeBytes: 256 * 1024 * 1024 * 1024, // 256 GiB removable — could be legit, warn
		Removable: true,
	}
	got := AssessWriteTarget(d)
	if !got.Allowed {
		t.Fatalf("expected allowed for a 256GiB removable")
	}
	if len(got.Warnings) == 0 {
		t.Fatalf("expected a warning on size")
	}
}

func TestAssessWriteTarget_BlocksZeroSize(t *testing.T) {
	got := AssessWriteTarget(DiskInfo{ID: "x", SizeBytes: 0, Removable: true})
	if got.Allowed {
		t.Fatalf("expected disallowed for zero-size")
	}
}

func TestAssessWriteTarget_BlocksTinyDisk(t *testing.T) {
	got := AssessWriteTarget(DiskInfo{ID: "x", SizeBytes: 4096, Removable: true})
	if got.Allowed {
		t.Fatalf("expected disallowed for 4KiB disk")
	}
}

func TestAssessWriteTarget_BlocksSystemMount(t *testing.T) {
	d := DiskInfo{
		ID:        "sda",
		SizeBytes: 32 * 1024 * 1024 * 1024,
		Removable: true,
		Partitions: []Partition{
			{Index: 1, Mountpoint: "/", Filesystem: "ext4", SizeBytes: 16 << 30},
		},
	}
	got := AssessWriteTarget(d)
	if got.Allowed {
		t.Fatalf("expected disallowed when a partition is mounted at /")
	}
}

func TestAssessWriteTarget_NonRemovableWindowsBlocked(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("windows-only semantics")
	}
	d := DiskInfo{
		ID:        "PhysicalDrive0",
		SizeBytes: 32 * 1024 * 1024 * 1024,
		Removable: false,
	}
	got := AssessWriteTarget(d)
	if got.Allowed {
		t.Fatalf("expected disallowed on Windows for non-removable disks")
	}
}
