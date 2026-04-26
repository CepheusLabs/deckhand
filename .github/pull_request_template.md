<!--
Thanks for contributing. A few notes before you submit:

1. If this PR touches a disk-write, profile-fetch, elevation, or IPC
   handler path, tick the security boxes below — not doing so is the
   fastest way to have a reviewer bounce your PR for a rewrite.
2. If you added or changed a sidecar RPC method, regenerate the docs
   with `go run ./cmd/deckhand-ipc-docs` before pushing. CI runs
   `--check` against your commit.
3. Dart: `dart format` + `flutter analyze --fatal-infos` must be
   clean. Go: `gofmt` + `go vet` + `golangci-lint run`.
-->

## What this changes

<!-- One paragraph, plain English. What behavior changes? What now works that didn't, or what is now safer that was risky? -->

## Why

<!-- Link an issue if applicable. Otherwise, explain the motivation. -->

## Testing done

<!-- Unit tests, integration tests, hardware-in-the-loop runs. -->

- [ ] `go test -race -count=1 ./...` clean
- [ ] `flutter test` clean for every touched package
- [ ] `flutter analyze --fatal-infos` clean for every touched package
- [ ] Ran against a real printer (describe)
- [ ] Ran `deckhand-sidecar doctor` — all [PASS]

## Security-sensitive changes (fill in ONE section)

### This PR does NOT touch any of:
- [ ] Disk write / read paths
- [ ] Profile fetch or verification
- [ ] Elevation paths (UAC / pkexec / osascript)
- [ ] JSON-RPC handler surface
- [ ] Signing, SBOM, or release pipeline

### OR: this PR touches one of the above — confirm:
- [ ] No new path writes to a disk that `disks.safety_check` has not approved.
- [ ] No new code executes profile-supplied Dart or shell without gating on `ProfileScriptRuntime.enabled`.
- [ ] New/changed `disks.*` or `os.*` RPCs declare a `ParamSpec`.
- [ ] No secrets / tokens / PGP keyrings leak into `deckhand-sidecar.log` (`redactParams` covers them).
- [ ] Downloaded artifacts are verified against a sha256 before use.
- [ ] Failing signed-tag check fails the operation, not just logs a warning.
- [ ] Regenerated `docs/IPC-METHODS.md` (if handler surface changed).

## Screenshots / traces

<!-- Optional. UX changes benefit from before/after screenshots. -->
