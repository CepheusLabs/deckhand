package hash

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSHA256KnownValue(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "foo.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := SHA256(path)
	if err != nil {
		t.Fatal(err)
	}
	// sha256("hello") — canonical value
	want := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	if got != want {
		t.Fatalf("sha256 mismatch: got %s, want %s", got, want)
	}
}

func TestSHA256MissingFile(t *testing.T) {
	_, err := SHA256(filepath.Join(t.TempDir(), "nonexistent"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}
