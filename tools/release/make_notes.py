#!/usr/bin/env python3
"""Собирает текст страницы релиза: кнопки загрузки + раздел из CHANGELOG.md.

Запуск в CI:  TAG=v0.2.0 REPO=vyto4ka/vysh python3 tools/release/make_notes.py dist > notes.md
Название релиза пишется в $GITHUB_OUTPUT (name=...).
"""
import os
import pathlib
import re
import subprocess
import sys
from urllib.parse import quote

tag = os.environ["TAG"]
repo = os.environ.get("REPO", "vyto4ka/vysh")
version = tag.lstrip("v")
dist = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dist")

# ── Раздел версии из CHANGELOG.md ────────────────────────────────────
changelog = pathlib.Path("CHANGELOG.md")
title, changes = "", ""
if changelog.exists():
    text = changelog.read_text(encoding="utf-8")
    m = re.search(
        rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M
    )
    if m:
        body = m.group(1).strip()
        t = re.match(r"^>\s*(.+)\n?", body)
        if t:
            title = t.group(1).strip()
            body = body[t.end():].strip()
        # Ссылки вида (docs/…) делаем абсолютными - страница релиза их иначе не найдёт.
        changes = re.sub(
            r"\]\((?!https?://)([^)]+)\)",
            lambda mm: f"](https://github.com/{repo}/blob/{tag}/{mm.group(1)})",
            body,
        )
if not changes:
    changes = "_Список изменений для этой версии не заполнен в CHANGELOG.md._"

# ── Кнопки загрузки (как бейджи shields.io) ──────────────────────────
KINDS = [
    # (суффикс файла, платформа, тип, цвет, логотип, цвет логотипа)
    ("windows-x64.zip", "Windows", "x64 ZIP", "0078D6", "windows", "white"),
    ("windows-x64-setup.exe", "Windows", "установщик", "0078D6", "windows", "white"),
    (".AppImage", "Linux", "AppImage", "F7C600", "linux", "black"),
    (".deb", "Debian / Ubuntu", "DEB", "A81D33", "debian", "white"),
    (".rpm", "Fedora / openSUSE", "RPM", "294172", "fedora", "white"),
    ("linux-x64.tar.gz", "Linux", "tar.gz", "333333", "linux", "white"),
    (".apk", "Android", "APK", "3DDC84", "android", "white"),
]


def badge(label, message, color, logo, logo_color):
    esc = lambda s: quote(s.replace("-", "--").replace("_", "__"), safe="")
    return (
        f"https://img.shields.io/badge/{esc(label)}-{esc(message)}-{color}"
        f"?style=for-the-badge&logo={logo}&logoColor={logo_color}&labelColor=3a3a3a"
    )


files = sorted(p.name for p in dist.iterdir() if p.is_file()) if dist.exists() else []
buttons = []
for suffix, label, kind, color, logo, logo_color in KINDS:
    for name in files:
        if name.endswith(suffix):
            url = f"https://github.com/{repo}/releases/download/{tag}/{quote(name)}"
            img = badge(label, kind, color, logo, logo_color)
            buttons.append(f'<a href="{url}"><img src="{img}" alt="{label} {kind}"></a>')

# ── Ссылка «все изменения» с прошлого тега ───────────────────────────
prev = ""
try:
    tags = subprocess.run(
        ["git", "tag", "--sort=-v:refname"], capture_output=True, text=True, check=True
    ).stdout.split()
    older = [t for t in tags if t != tag and not "-" in t]
    after = tags.index(tag) + 1 if tag in tags else 0
    rest = [t for t in tags[after:] if "-" not in t]
    prev = rest[0] if rest else ""
except Exception:
    pass

# ── Текст ────────────────────────────────────────────────────────────
out = []
if buttons:
    # Иконка над кнопками - если она есть в репозитории на момент тега.
    if os.path.exists("assets/icon/vysh.png"):
        out.append(
            f'<p align="center"><img src="https://raw.githubusercontent.com/{repo}/{tag}'
            f'/assets/icon/vysh.png" width="96" alt=""></p>\n'
        )
    out.append('<p align="center">')
    out.append("<br>\n".join(buttons))
    out.append("</p>\n")
out.append(changes)
out.append(
    "\n### 📦 Установка\n"
    "**Windows:** распакуйте zip и запустите `vysh.exe`. "
    "SmartScreen может предупредить о неизвестном издателе: «Подробнее» → «Выполнить в любом случае».\n\n"
    "**Linux:** распакуйте архив и запустите `./vysh` (нужны `libgtk-3` и `libsecret-1`).\n\n"
    "**Обновление:** замените папку с программой: хосты, настройки и пароли хранятся отдельно и сохранятся."
)
if prev:
    out.append(f"\n**Все изменения:** [{prev}…{tag}](https://github.com/{repo}/compare/{prev}...{tag})")

print("\n".join(out))

name = f"vysh {version}" + (f": {title}" if title else "")
gh_out = os.environ.get("GITHUB_OUTPUT")
if gh_out:
    with open(gh_out, "a", encoding="utf-8") as f:
        f.write(f"name={name}\n")
else:
    print(f"\n<!-- name: {name} -->", file=sys.stderr)
