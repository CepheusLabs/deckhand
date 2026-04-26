package disks

import (
	"encoding/json"
	"strings"
)

// parseDiskEnumField decodes a `Get-Disk` enum field (BusType,
// OperationalStatus) into a canonical (int, name) pair.
//
// The JSON shape depends on the PowerShell Storage-module version:
//   - Older modules serialize the enum as a number: `"BusType": 17`
//   - PowerShell 7+ serializes it as the enum member name: `"BusType": "NVMe"`
//
// Decoding to a fixed `int` struct field (as the original code did)
// blows up with `json: cannot unmarshal string into Go field ... of
// type int` on the newer shape. This helper accepts both, returning
// zero + "Unknown" on any unexpected value.
func parseDiskEnumField(raw json.RawMessage, names map[int]string) (int, string) {
	// Empty / null / missing — treat as unknown.
	trim := strings.TrimSpace(string(raw))
	if trim == "" || trim == "null" {
		return 0, "Unknown"
	}
	var n int
	if err := json.Unmarshal(raw, &n); err == nil {
		if name, ok := names[n]; ok {
			return n, name
		}
		return n, "Unknown"
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		if n, ok := nameToIndex(names, s); ok {
			return n, names[n]
		}
		// Caller still gets the raw string as the display name even
		// when we couldn't map it back to a numeric index — better
		// than "Unknown" because at least the user sees "NVMe".
		return 0, s
	}
	return 0, "Unknown"
}

func nameToIndex(names map[int]string, s string) (int, bool) {
	target := strings.EqualFold
	for i, n := range names {
		if target(n, s) {
			return i, true
		}
	}
	return 0, false
}

// busTypeNames maps Get-Disk BusType enum values to their canonical
// names. Reference:
// https://learn.microsoft.com/en-us/previous-versions/windows/desktop/stormgmt/msft-disk
var busTypeNames = map[int]string{
	1:  "SCSI",
	2:  "ATAPI",
	3:  "ATA",
	4:  "1394",
	5:  "SSA",
	6:  "FibreChannel",
	7:  "USB",
	8:  "RAID",
	9:  "iSCSI",
	10: "SAS",
	11: "SATA",
	12: "SD",
	13: "MMC",
	14: "Virtual",
	15: "FileBackedVirtual",
	16: "StorageSpaces",
	17: "NVMe",
}

// busTypeName is retained for code that already looked up enum names by
// number; new code should prefer parseDiskEnumField.
func busTypeName(b int) string {
	if name, ok := busTypeNames[b]; ok {
		return name
	}
	return "Unknown"
}

// isRemovableBus now accepts the canonical name (case-insensitive) so
// it works whether the caller received a number or a string from
// PowerShell. USB / SD / MMC disks are reported as removable.
func isRemovableBus(name string) bool {
	switch strings.ToLower(name) {
	case "usb", "sd", "mmc":
		return true
	}
	return false
}
