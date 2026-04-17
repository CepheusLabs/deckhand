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

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// DownloadProgress is the payload of `progress` notifications emitted
// while a download is in flight.
type DownloadProgress struct {
	BytesDone  int64  `json:"bytes_done"`
	BytesTotal int64  `json:"bytes_total"`
	Phase      string `json:"phase"`
}

// Download fetches [url] to [destPath], streaming progress through [note].
// If [expectedSha] is non-empty, verifies the final file matches.
func Download(ctx context.Context, url, destPath, expectedSha string, note rpc.Notifier) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return "", fmt.Errorf("open dest: %w", err)
	}
	defer f.Close()

	hasher := sha256.New()
	mw := io.MultiWriter(f, hasher)

	total := resp.ContentLength
	var done int64
	lastNotified := int64(0)
	buf := make([]byte, 1<<20)

	for {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				return "", fmt.Errorf("write: %w", werr)
			}
			done += int64(n)
			if note != nil && done-lastNotified >= 4<<20 { // every 4 MiB
				note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "downloading"})
				lastNotified = done
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", fmt.Errorf("read: %w", rerr)
		}
	}

	actual := hex.EncodeToString(hasher.Sum(nil))
	if expectedSha != "" && actual != expectedSha {
		return "", fmt.Errorf("sha256 mismatch: got %s, want %s", actual, expectedSha)
	}
	if note != nil {
		note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "done"})
	}
	return actual, nil
}
