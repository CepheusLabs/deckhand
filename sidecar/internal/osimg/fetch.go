// Package osimg downloads OS images with resume + sha256 verification.
package osimg

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
)

// Download fetches [url] to [destPath], streaming progress through [onProgress].
// If [expectedSha] is non-empty, verifies the final file matches; returns an
// error if it doesn't.
func Download(
	ctx context.Context,
	url, destPath, expectedSha string,
	onProgress func(bytesDone, bytesTotal int64),
) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("open dest: %w", err)
	}
	defer f.Close()

	hasher := sha256.New()
	mw := io.MultiWriter(f, hasher)

	total := resp.ContentLength
	var done int64
	buf := make([]byte, 1<<20) // 1 MiB

	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				return fmt.Errorf("write: %w", werr)
			}
			done += int64(n)
			if onProgress != nil {
				onProgress(done, total)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("read: %w", rerr)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}

	actual := hex.EncodeToString(hasher.Sum(nil))
	if expectedSha != "" && actual != expectedSha {
		return fmt.Errorf("sha256 mismatch: got %s, want %s", actual, expectedSha)
	}
	return nil
}
