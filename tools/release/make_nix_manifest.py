#!/usr/bin/env python3
"""Обновляет packaging/nix/release.json по собранному Linux-архиву релиза.

Вычисляет SRI-хеш (sha256-<base64>) для dist/vysh-<TAG>-linux-x64.tar.gz
и записывает версию, тег, URL и хеш в JSON для flake.nix / packaging/nix/package.nix.

Запуск в CI:
    TAG=v0.7.7 REPO=vyto4ka/vysh python3 tools/release/make_nix_manifest.py dist
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import sys


def sha256_sri(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256-" + base64.b64encode(digest.digest()).decode("ascii")


def build_manifest(tag: str, repo: str, archive: pathlib.Path) -> dict[str, str]:
    version = tag.lstrip("v")
    return {
        "version": version,
        "tag": tag,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{archive.name}",
        "hash": sha256_sri(archive),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Сформировать packaging/nix/release.json из Linux-архива релиза."
    )
    parser.add_argument(
        "dist",
        nargs="?",
        default="dist",
        help="Каталог с артефактами релиза (по умолчанию dist).",
    )
    parser.add_argument(
        "--tag",
        default=os.environ.get("TAG", ""),
        help="Тег релиза, например v0.7.7 (или переменная окружения TAG).",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("REPO", "vyto4ka/vysh"),
        help="Репозиторий GitHub в формате owner/name (или REPO).",
    )
    parser.add_argument(
        "--output",
        default="packaging/nix/release.json",
        help="Куда записать JSON-манифест.",
    )
    args = parser.parse_args(argv)

    if not args.tag:
        sys.exit("не задан тег релиза (--tag или переменная окружения TAG)")

    dist = pathlib.Path(args.dist)
    archive = dist / f"vysh-{args.tag}-linux-x64.tar.gz"
    if not archive.exists():
        sys.exit(f"нет {archive}: Linux-сборка не попала в {dist}")

    manifest = build_manifest(args.tag, args.repo, archive)
    out_path = pathlib.Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Nix manifest {manifest['version']}, {manifest['hash']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
