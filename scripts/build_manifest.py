#!/usr/bin/env python3
"""Emit a release manifest the marketing site consumes.

Replaces the GitHub-API scrape `site/app.js` used to do on page load:
the site fetches a static JSON manifest that this script produces as
part of the release pipeline, keyed by platform + arch, with sha256
digests and .asc URLs for every artifact.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# Artifact filename -> (platform, arch) mapping. Kept intentionally
# narrow: manifest consumers key off canonical strings. Every pattern
# is case-insensitive — release artifacts are conventionally named
# "Deckhand-…" but a future packaging tweak shouldn't silently drop
# them from the manifest because the regex was case-sensitive.
PLATFORMS = (
    (re.compile(r"deckhand.*\.exe$", re.I),         "windows", "x64"),
    (re.compile(r"deckhand.*-x86_64.*\.AppImage$", re.I), "linux", "x64"),
    (re.compile(r"deckhand.*\.AppImage$", re.I),    "linux",   "x64"),
    (re.compile(r"deckhand.*-arm64.*\.dmg$", re.I), "macos",   "arm64"),
    (re.compile(r"deckhand.*-amd64.*\.dmg$", re.I), "macos",   "x64"),
    (re.compile(r"deckhand.*\.dmg$", re.I),         "macos",   "universal"),
)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def classify(name: str) -> tuple[str, str] | None:
    for pat, plat, arch in PLATFORMS:
        if pat.search(name):
            return plat, arch
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--artifacts-dir", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument(
        "--download-base",
        default=None,
        help=(
            "URL prefix for files in the manifest. If omitted, the "
            "manifest uses relative paths so consumers can join with "
            "their release base URL."
        ),
    )
    args = ap.parse_args()

    root: Path = args.artifacts_dir
    if not root.is_dir():
        print(f"artifacts dir does not exist: {root}", file=sys.stderr)
        return 2

    entries: list[dict] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.name in {"manifest.json", "SHA256SUMS", "SHA256SUMS.asc"}:
            continue
        if path.suffix in {".asc", ".sig"}:
            continue
        classified = classify(path.name)
        if classified is None:
            continue
        plat, arch = classified
        rel = path.relative_to(root).as_posix()
        url = f"{args.download_base.rstrip('/')}/{rel}" if args.download_base else rel
        sig_path = path.with_name(path.name + ".asc")
        sig_url = None
        if sig_path.exists():
            sig_rel = sig_path.relative_to(root).as_posix()
            sig_url = (
                f"{args.download_base.rstrip('/')}/{sig_rel}"
                if args.download_base
                else sig_rel
            )
        entries.append(
            {
                "platform": plat,
                "arch": arch,
                "filename": path.name,
                "url": url,
                "sha256": sha256_of(path),
                "size": path.stat().st_size,
                "signature_url": sig_url,
            }
        )

    manifest = {
        "schema": "deckhand.release/1",
        "version": args.version,
        "build": args.build,
        "tag": args.tag,
        "ref": args.ref,
        "sha256sums": "SHA256SUMS",
        "sha256sums_signature": "SHA256SUMS.asc",
        "artifacts": entries,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
