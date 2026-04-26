"""Unit tests for build_manifest.py.

Covers the artifact classification regex (which decides whether a
file lands in the manifest at all and which platform/arch it gets
keyed under) plus the end-to-end JSON shape. Designed to run with
the standard library's unittest — no extra dependencies.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "build_manifest.py"

# Import the module so the unit tests can call into `classify` and
# `sha256_of` directly without going through subprocess.
sys.path.insert(0, str(REPO_ROOT / "scripts"))
import build_manifest  # type: ignore[import-not-found]  # noqa: E402


class ClassifyTests(unittest.TestCase):
    """Pin the platform/arch routing the release pipeline relies on."""

    def assert_match(self, name: str, plat: str, arch: str) -> None:
        got = build_manifest.classify(name)
        self.assertEqual(got, (plat, arch), f"unexpected classification for {name!r}: {got!r}")

    def assert_no_match(self, name: str) -> None:
        self.assertIsNone(build_manifest.classify(name),
                          f"expected no match for {name!r}, got {build_manifest.classify(name)!r}")

    def test_windows_exe(self) -> None:
        self.assert_match("Deckhand-26.4.18-x64-setup.exe", "windows", "x64")

    def test_linux_appimage_with_arch(self) -> None:
        self.assert_match("Deckhand-26.4.18-x86_64.AppImage", "linux", "x64")

    def test_linux_appimage_without_arch(self) -> None:
        self.assert_match("Deckhand-26.4.18.AppImage", "linux", "x64")

    def test_macos_arm64(self) -> None:
        self.assert_match("Deckhand-26.4.18-arm64.dmg", "macos", "arm64")

    def test_macos_amd64(self) -> None:
        self.assert_match("Deckhand-26.4.18-amd64.dmg", "macos", "x64")

    def test_macos_universal_dmg(self) -> None:
        self.assert_match("Deckhand-26.4.18.dmg", "macos", "universal")

    def test_case_insensitive_extensions(self) -> None:
        self.assert_match("Deckhand.EXE", "windows", "x64")
        self.assert_match("Deckhand.DMG", "macos", "universal")

    def test_unrelated_files_skipped(self) -> None:
        self.assert_no_match("README.md")
        self.assert_no_match("manifest.json")
        self.assert_no_match("SHA256SUMS")
        self.assert_no_match("SHA256SUMS.asc")
        self.assert_no_match("Deckhand-26.4.18.tar.gz")
        self.assert_no_match("notes.txt")

    def test_signature_files_classify_off_filename(self) -> None:
        # Signature files shouldn't classify as artifacts; the script
        # later filters .asc / .sig anyway. This guards against a
        # future regex change accidentally matching them.
        self.assert_no_match("Deckhand-26.4.18-x64-setup.exe.asc")
        self.assert_no_match("Deckhand-26.4.18.dmg.sig")


class Sha256Tests(unittest.TestCase):
    def test_matches_hashlib(self) -> None:
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"hello deckhand")
            path = Path(f.name)
        try:
            self.assertEqual(build_manifest.sha256_of(path),
                             hashlib.sha256(b"hello deckhand").hexdigest())
        finally:
            path.unlink()


class EndToEndTests(unittest.TestCase):
    """Drive build_manifest.py as a subprocess against a fixture."""

    def test_full_manifest_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            arts = tmp_path / "release-artifacts"
            arts.mkdir()
            # Lay out a realistic release.
            (arts / "Deckhand-26.4.18-x64-setup.exe").write_bytes(b"\x4d\x5a windows")
            (arts / "Deckhand-26.4.18-arm64.dmg").write_bytes(b"\xCAarm64")
            (arts / "Deckhand-26.4.18-amd64.dmg").write_bytes(b"\xCAamd64")
            (arts / "Deckhand-26.4.18-x86_64.AppImage").write_bytes(b"AppImg")
            (arts / "Deckhand-26.4.18-x86_64.AppImage.asc").write_bytes(b"sig")
            # Files that must NOT appear in the manifest.
            (arts / "SHA256SUMS").write_bytes(b"checksums")
            (arts / "SHA256SUMS.asc").write_bytes(b"sig")
            (arts / "manifest.json").write_bytes(b"will be overwritten")
            (arts / "release-notes.txt").write_bytes(b"notes")

            out = arts / "manifest.json"
            env = dict(os.environ)
            # Make sure we don't accidentally fetch from the network.
            env.pop("PYTHONPATH", None)
            res = subprocess.run(
                [sys.executable, str(SCRIPT),
                 "--version", "26.4.18", "--build", "1247",
                 "--tag", "v26.4.18-1247", "--ref", "deadbeef" * 5,
                 "--artifacts-dir", str(arts), "--output", str(out)],
                check=True, capture_output=True, env=env,
            )
            self.assertEqual(res.returncode, 0, msg=res.stderr.decode())
            manifest = json.loads(out.read_text())

            self.assertEqual(manifest["schema"], "deckhand.release/1")
            self.assertEqual(manifest["version"], "26.4.18")
            self.assertEqual(manifest["tag"], "v26.4.18-1247")
            self.assertEqual(manifest["sha256sums"], "SHA256SUMS")
            self.assertEqual(manifest["sha256sums_signature"], "SHA256SUMS.asc")

            classified = {(a["platform"], a["arch"]): a for a in manifest["artifacts"]}
            self.assertIn(("windows", "x64"), classified)
            self.assertIn(("macos", "arm64"), classified)
            self.assertIn(("macos", "x64"), classified)
            self.assertIn(("linux", "x64"), classified)

            # Linux entry must have signature_url since .AppImage.asc exists.
            linux = classified[("linux", "x64")]
            self.assertEqual(linux["signature_url"], "Deckhand-26.4.18-x86_64.AppImage.asc")

            # Windows entry has no .asc → signature_url is null.
            self.assertIsNone(classified[("windows", "x64")]["signature_url"])

            # No SHA256SUMS / manifest.json / release-notes in artifacts.
            names = {a["filename"] for a in manifest["artifacts"]}
            self.assertNotIn("SHA256SUMS", names)
            self.assertNotIn("SHA256SUMS.asc", names)
            self.assertNotIn("manifest.json", names)
            self.assertNotIn("release-notes.txt", names)

            # SHA256 in the manifest matches what hashlib computes.
            for art in manifest["artifacts"]:
                src = arts / art["filename"]
                self.assertEqual(art["sha256"], hashlib.sha256(src.read_bytes()).hexdigest())
                self.assertEqual(art["size"], src.stat().st_size)


class DownloadBaseTests(unittest.TestCase):
    """When the release pipeline passes --download-base, every entry's
    `url` and `signature_url` must be the absolute URL the site can
    consume. Without --download-base they stay relative."""

    def _run(self, *, download_base):
        with tempfile.TemporaryDirectory() as tmp:
            arts = Path(tmp) / "release-artifacts"
            arts.mkdir()
            (arts / "Deckhand-26.4.18-x86_64.AppImage").write_bytes(b"img")
            (arts / "Deckhand-26.4.18-x86_64.AppImage.asc").write_bytes(b"sig")
            (arts / "Deckhand-26.4.18-x64-setup.exe").write_bytes(b"win")
            out = arts / "manifest.json"
            args = [
                sys.executable, str(SCRIPT),
                "--version", "26.4.18", "--build", "1247",
                "--tag", "v26.4.18-1247", "--ref", "deadbeef" * 5,
                "--artifacts-dir", str(arts), "--output", str(out),
            ]
            if download_base is not None:
                args += ["--download-base", download_base]
            res = subprocess.run(args, check=True, capture_output=True)
            self.assertEqual(res.returncode, 0, msg=res.stderr.decode())
            return json.loads(out.read_text())

    def test_relative_when_download_base_omitted(self):
        manifest = self._run(download_base=None)
        for art in manifest["artifacts"]:
            self.assertFalse(
                art["url"].startswith("http"),
                f"url should be relative: {art['url']!r}",
            )
            if art["signature_url"] is not None:
                self.assertFalse(
                    art["signature_url"].startswith("http"),
                    f"signature_url should be relative: {art['signature_url']!r}",
                )

    def test_absolute_when_download_base_passed(self):
        base = "https://github.com/CepheusLabs/deckhand/releases/download/v26.4.18-1247"
        manifest = self._run(download_base=base)
        for art in manifest["artifacts"]:
            self.assertTrue(
                art["url"].startswith(base + "/"),
                f"url should be prefixed with {base}: {art['url']!r}",
            )
            if art["signature_url"] is not None:
                self.assertTrue(
                    art["signature_url"].startswith(base + "/"),
                    f"signature_url should be prefixed with {base}: "
                    f"{art['signature_url']!r}",
                )

    def test_trailing_slash_in_download_base_normalised(self):
        # build_manifest strips the trailing slash before joining; pin
        # this so a future refactor that drops the rstrip doesn't
        # produce double-slashed URLs (which silently 404 on
        # GitHub's CDN).
        base_with_slash = "https://example.com/releases/v1/"
        manifest = self._run(download_base=base_with_slash)
        for art in manifest["artifacts"]:
            tail = art["url"].split("://", 1)[1]
            self.assertNotIn("//", tail,
                             f"unexpected double slash in {art['url']!r}")


class SignatureUrlResolutionTests(unittest.TestCase):
    """`signature_url` is null when no `<artifact>.asc` is present;
    populated (relative or absolute, matching url's shape) when one
    exists."""

    def test_signature_null_when_no_asc(self):
        with tempfile.TemporaryDirectory() as tmp:
            arts = Path(tmp) / "r"
            arts.mkdir()
            (arts / "Deckhand-1.exe").write_bytes(b"x")
            out = arts / "manifest.json"
            subprocess.run(
                [sys.executable, str(SCRIPT),
                 "--version", "1", "--build", "1",
                 "--tag", "v1-1", "--ref", "0" * 40,
                 "--artifacts-dir", str(arts), "--output", str(out)],
                check=True,
            )
            manifest = json.loads(out.read_text())
            self.assertEqual(len(manifest["artifacts"]), 1)
            self.assertIsNone(manifest["artifacts"][0]["signature_url"])

    def test_signature_populated_when_asc_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            arts = Path(tmp) / "r"
            arts.mkdir()
            (arts / "Deckhand-1.AppImage").write_bytes(b"x")
            (arts / "Deckhand-1.AppImage.asc").write_bytes(b"sig")
            out = arts / "manifest.json"
            subprocess.run(
                [sys.executable, str(SCRIPT),
                 "--version", "1", "--build", "1",
                 "--tag", "v1-1", "--ref", "0" * 40,
                 "--artifacts-dir", str(arts), "--output", str(out)],
                check=True,
            )
            manifest = json.loads(out.read_text())
            sig = manifest["artifacts"][0]["signature_url"]
            self.assertIsNotNone(sig)
            self.assertTrue(sig.endswith(".asc"))


class ManifestSchemaTests(unittest.TestCase):
    """Pin the top-level + per-artifact keys the site consumes."""

    def _build(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__('shutil').rmtree(tmp, ignore_errors=True))
        arts = Path(tmp) / "r"
        arts.mkdir()
        (arts / "Deckhand-1.exe").write_bytes(b"x")
        out = arts / "manifest.json"
        subprocess.run(
            [sys.executable, str(SCRIPT),
             "--version", "1", "--build", "1",
             "--tag", "v1-1", "--ref", "0" * 40,
             "--artifacts-dir", str(arts), "--output", str(out)],
            check=True,
        )
        return json.loads(out.read_text())

    def test_top_level_keys(self):
        manifest = self._build()
        self.assertEqual(
            set(manifest.keys()),
            {"schema", "version", "build", "tag", "ref",
             "sha256sums", "sha256sums_signature", "artifacts"},
        )
        self.assertEqual(manifest["schema"], "deckhand.release/1")

    def test_artifact_keys(self):
        manifest = self._build()
        self.assertEqual(
            set(manifest["artifacts"][0].keys()),
            {"platform", "arch", "filename", "url",
             "sha256", "size", "signature_url"},
        )


if __name__ == "__main__":
    unittest.main()
