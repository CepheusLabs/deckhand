package disks

import (
	"context"
	"errors"
)

// ErrElevationRequired is returned by WriteImage to tell the caller it
// must re-dispatch the operation via the elevated helper.
var ErrElevationRequired = errors.New("disks.write_image: elevation required; dispatch via deckhand-elevated-helper")

// WriteImage is the main-sidecar stub. Real writes happen in the elevated
// helper binary. This path exists so handlers can return a structured
// ErrElevationRequired without special-casing at the handler layer.
func WriteImage(ctx context.Context, imagePath, diskID, confirmationToken string) error {
	return ErrElevationRequired
}
