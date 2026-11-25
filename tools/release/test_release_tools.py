#!/usr/bin/env python3
"""Тесты скриптов упаковки релиза (Arch PKGBUILD и Nix release.json)."""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "release"))

import make_nix_manifest  # noqa: E402


class ReleaseToolsTest(unittest.TestCase):
    def test_make_nix_manifest_generates_valid_sri_and_url(self) -> None:
        payload = b"vysh-linux-bundle-test-bytes"
        expected_sri = (
            "sha256-"
            + base64.b64encode(hashlib.sha256(payload).digest()).decode("ascii")
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            dist = tmp_path / "dist"
            dist.mkdir()
            archive = dist / "vysh-v1.2.3-linux-x64.tar.gz"
            archive.write_bytes(payload)
            out = tmp_path / "release.json"

            code = make_nix_manifest.main(
                [
                    str(dist),
                    "--tag",
                    "v1.2.3",
                    "--repo",
                    "vyto4ka/vysh",
                    "--output",
                    str(out),
                ]
            )
            self.assertEqual(code, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["version"], "1.2.3")
            self.assertEqual(data["tag"], "v1.2.3")
            self.assertEqual(
                data["url"],
                "https://github.com/vyto4ka/vysh/releases/download/v1.2.3/vysh-v1.2.3-linux-x64.tar.gz",
            )
            self.assertEqual(data["hash"], expected_sri)

    def test_committed_nix_release_manifest_is_valid(self) -> None:
        manifest_path = REPO_ROOT / "packaging" / "nix" / "release.json"
        self.assertTrue(manifest_path.exists(), "packaging/nix/release.json должен существовать")
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        for key in ("version", "tag", "url", "hash"):
            self.assertIn(key, data)
            self.assertIsInstance(data[key], str)
            self.assertTrue(data[key])
        self.assertEqual(data["tag"], f"v{data['version']}")
        self.assertTrue(data["hash"].startswith("sha256-"))
        raw = base64.b64decode(data["hash"].removeprefix("sha256-"), validate=True)
        self.assertEqual(len(raw), 32)
        self.assertTrue(data["url"].endswith(f"vysh-{data['tag']}-linux-x64.tar.gz"))

    def test_make_pkgbuild_substitutes_version_and_sha256(self) -> None:
        payload = b"vysh-arch-test-bytes"
        expected_sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as tmp:
            dist = pathlib.Path(tmp)
            archive = dist / "vysh-v1.2.3-linux-x64.tar.gz"
            archive.write_bytes(payload)

            env = {**os.environ, "TAG": "v1.2.3"}
            proc = subprocess.run(
                [sys.executable, str(REPO_ROOT / "tools/release/make_pkgbuild.py"), str(dist)],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            pkgbuild = (dist / "PKGBUILD").read_text(encoding="utf-8")
            self.assertIn("pkgver=1.2.3", pkgbuild)
            self.assertIn(f"sha256sums=('{expected_sha}')", pkgbuild)
            self.assertNotIn("@PKGVER@", pkgbuild)
            self.assertNotIn("@SHA256@", pkgbuild)


if __name__ == "__main__":
    unittest.main()
