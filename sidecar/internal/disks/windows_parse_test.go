package disks

import (
	"encoding/json"
	"testing"
)

// TestParseDiskEnumField covers every BusType JSON shape we've
// observed across PowerShell versions. The old code only handled
// integers and blew up with a `cannot unmarshal string into Go
// field of type int` on any PS 7+ host.
func TestParseDiskEnumField(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantN    int
		wantName string
	}{
		{"integer BusType (legacy PS)", `17`, 17, "NVMe"},
		{"string BusType (PS 7+)", `"NVMe"`, 17, "NVMe"},
		{"string USB (case-insensitive)", `"USB"`, 7, "USB"},
		{"mixed-case string", `"nVmE"`, 17, "NVMe"},
		{"unknown integer — numeric kept, name unknown", `99`, 99, "Unknown"},
		{"unknown string — display the raw name", `"MyBus"`, 0, "MyBus"},
		{"null", `null`, 0, "Unknown"},
		{"empty", ``, 0, "Unknown"},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			var raw json.RawMessage
			if tc.input != "" {
				raw = json.RawMessage(tc.input)
			}
			gotN, gotName := parseDiskEnumField(raw, busTypeNames)
			if gotN != tc.wantN || gotName != tc.wantName {
				t.Fatalf("parseDiskEnumField(%q) = (%d, %q); want (%d, %q)",
					tc.input, gotN, gotName, tc.wantN, tc.wantName)
			}
		})
	}
}

func TestIsRemovableBus(t *testing.T) {
	tests := []struct {
		name string
		bus  string
		want bool
	}{
		{"USB is removable", "USB", true},
		{"usb lowercase", "usb", true},
		{"SD is removable", "SD", true},
		{"MMC is removable", "MMC", true},
		{"NVMe is not removable", "NVMe", false},
		{"SATA is not removable", "SATA", false},
		{"unknown is not removable", "MyBus", false},
		{"empty is not removable", "", false},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if got := isRemovableBus(tc.bus); got != tc.want {
				t.Fatalf("isRemovableBus(%q) = %v; want %v", tc.bus, got, tc.want)
			}
		})
	}
}

func TestBusTypeName(t *testing.T) {
	// Spot-check a few values; the full table lives in windows_parse.go.
	for _, tc := range []struct {
		in   int
		want string
	}{
		{7, "USB"},
		{11, "SATA"},
		{17, "NVMe"},
		{0, "Unknown"},
		{100, "Unknown"},
	} {
		if got := busTypeName(tc.in); got != tc.want {
			t.Errorf("busTypeName(%d) = %q; want %q", tc.in, got, tc.want)
		}
	}
}
