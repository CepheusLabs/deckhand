//go:build windows

package disks

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
)

// List enumerates physical disks using PowerShell's Get-Disk cmdlet.
// We shell out because writing Win32 DeviceIoControl + IOCTL_DISK_*
// directly is considerably more code for the same information.
//
// BusType and OperationalStatus are decoded via parseDiskEnumField
// because their JSON shape varies by PowerShell version — old
// Storage modules emit integers, PS 7+ emits enum names. See
// windows_parse.go for the full story.
func List(ctx context.Context) ([]DiskInfo, error) {
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-Command",
		`Get-Disk | Select-Object Number,FriendlyName,Size,BusType,OperationalStatus | ConvertTo-Json -Compress`)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("Get-Disk failed: %w", err)
	}

	// ConvertTo-Json emits an object (not an array) if only one disk.
	type raw struct {
		Number            int             `json:"Number"`
		FriendlyName      string          `json:"FriendlyName"`
		Size              int64           `json:"Size"`
		BusType           json.RawMessage `json:"BusType"`
		OperationalStatus json.RawMessage `json:"OperationalStatus"`
	}
	var disks []raw
	if err := json.Unmarshal(out, &disks); err != nil {
		// Single disk case — retry as an object.
		var single raw
		if serr := json.Unmarshal(out, &single); serr == nil {
			disks = []raw{single}
		} else {
			return nil, fmt.Errorf("parse Get-Disk output: %w (%q)", err, string(out))
		}
	}

	results := make([]DiskInfo, 0, len(disks))
	for _, d := range disks {
		parts, perr := listPartitions(ctx, d.Number)
		if perr != nil {
			// Partition enumeration can fail for dynamic disks or
			// disks with no partition table. Surface an empty slice
			// rather than failing the whole list — the UI prefers
			// "disk visible, partitions unknown" to "disks.list
			// errored".
			parts = nil
		}
		_, busName := parseDiskEnumField(d.BusType, busTypeNames)
		results = append(results, DiskInfo{
			ID:         "PhysicalDrive" + strconv.Itoa(d.Number),
			Path:       `\\.\PHYSICALDRIVE` + strconv.Itoa(d.Number),
			SizeBytes:  d.Size,
			Bus:        busName,
			Model:      d.FriendlyName,
			Removable:  isRemovableBus(busName),
			Partitions: parts,
		})
	}
	return results, nil
}

func listPartitions(ctx context.Context, diskNumber int) ([]Partition, error) {
	// diskNumber is an int from a previously-parsed JSON integer (the
	// caller pulls it from Get-Disk output), so string interpolation
	// is safe here — there is no possible metacharacter path. Still,
	// assert >= 0 so a future caller passing a negative value via a
	// different path fails fast rather than producing weird PowerShell.
	if diskNumber < 0 {
		return nil, fmt.Errorf("invalid disk number %d", diskNumber)
	}
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-Command",
		fmt.Sprintf(`Get-Partition -DiskNumber %d | Select-Object PartitionNumber,Size,Type,DriveLetter | ConvertTo-Json -Compress`, diskNumber))
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("Get-Partition disk %d: %w", diskNumber, err)
	}
	type raw struct {
		PartitionNumber int    `json:"PartitionNumber"`
		Size            int64  `json:"Size"`
		Type            string `json:"Type"`
		DriveLetter     string `json:"DriveLetter"`
	}
	var parts []raw
	if err := json.Unmarshal(out, &parts); err != nil {
		var single raw
		if serr := json.Unmarshal(out, &single); serr == nil {
			parts = []raw{single}
		} else {
			return nil, err
		}
	}

	result := make([]Partition, 0, len(parts))
	for _, p := range parts {
		mp := ""
		if p.DriveLetter != "" {
			mp = p.DriveLetter + ":\\"
		}
		result = append(result, Partition{
			Index:      p.PartitionNumber,
			Filesystem: p.Type,
			SizeBytes:  p.Size,
			Mountpoint: mp,
		})
	}
	return result, nil
}
