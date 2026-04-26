package logging

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInit_CreatesFileAndWritesJSON(t *testing.T) {
	dir := t.TempDir()
	logger, closeFn, err := Init(dir)
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	defer func() { _ = closeFn() }()

	logger.Info("hello", "k", "v")

	// Close to flush.
	if err := closeFn(); err != nil {
		t.Fatalf("close: %v", err)
	}

	path := filepath.Join(dir, DefaultLogName)
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open log: %v", err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	if !scanner.Scan() {
		t.Fatalf("expected at least one log line, got none")
	}
	var row map[string]any
	if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
		t.Fatalf("log line is not JSON: %v (%q)", err, scanner.Text())
	}
	if row["msg"] != "hello" {
		t.Fatalf("msg field missing/wrong: %v", row["msg"])
	}
	if row["k"] != "v" {
		t.Fatalf("k field missing/wrong: %v", row["k"])
	}
	if row["level"] != "INFO" {
		t.Fatalf("level field missing/wrong: %v", row["level"])
	}
}

func TestInit_RotatesWhenFileFull(t *testing.T) {
	dir := t.TempDir()
	// Tiny rotation budget so we trigger it in a few writes.
	logger, closeFn, err := InitWithOptions(dir, Options{
		MaxFileBytes: 512,
		MaxFiles:     3,
		Filename:     "test.log",
	})
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	defer func() { _ = closeFn() }()

	// Each Info emits ~150 bytes of JSON, so 30 iterations fills and
	// rolls several times.
	for i := 0; i < 30; i++ {
		logger.Info("fill the file",
			"iter", i,
			"padding", strings.Repeat("x", 40),
		)
	}
	if err := closeFn(); err != nil {
		t.Fatalf("close: %v", err)
	}

	base := filepath.Join(dir, "test.log")
	// Current file must exist.
	if _, err := os.Stat(base); err != nil {
		t.Fatalf("current log missing: %v", err)
	}
	// At least one rotated file must exist; we wrote far more than
	// MaxFileBytes.
	backups := existingBackups(base)
	if len(backups) == 0 {
		t.Fatalf("expected at least one rotated backup, got none")
	}
	// No more than MaxFiles-1 backups (plus current file).
	if len(backups) > 2 {
		t.Fatalf("expected at most 2 backups (maxFiles=3), got %d: %v", len(backups), backups)
	}

	// Every rotated file must still be valid JSON lines.
	for _, b := range append([]string{base}, backups...) {
		f, err := os.Open(b)
		if err != nil {
			t.Fatalf("open %s: %v", b, err)
		}
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			if len(scanner.Bytes()) == 0 {
				continue
			}
			var row map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
				t.Fatalf("%s: bad json line: %v (%q)", b, err, scanner.Text())
			}
		}
		_ = f.Close()
	}
}

func TestInit_CapsTotalFiles(t *testing.T) {
	dir := t.TempDir()
	logger, closeFn, err := InitWithOptions(dir, Options{
		MaxFileBytes: 256,
		MaxFiles:     2, // current + .1 only
		Filename:     "capped.log",
	})
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	defer func() { _ = closeFn() }()

	for i := 0; i < 100; i++ {
		logger.Info("line", "i", i, "pad", strings.Repeat("x", 40))
	}
	if err := closeFn(); err != nil {
		t.Fatalf("close: %v", err)
	}

	base := filepath.Join(dir, "capped.log")
	backups := existingBackups(base)
	if len(backups) > 1 {
		t.Fatalf("expected <= 1 backup with MaxFiles=2, got %d: %v", len(backups), backups)
	}
}

func TestInit_EmptyDirErrors(t *testing.T) {
	if _, _, err := Init(""); err == nil {
		t.Fatalf("expected error for empty dataDir")
	}
}
