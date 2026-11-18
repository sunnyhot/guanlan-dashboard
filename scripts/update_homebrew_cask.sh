#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法: $0 <version> <release-zip> <homebrew-tap-dir>" >&2
    exit 64
fi

VERSION="$1"
ZIP_PATH="$2"
TAP_DIR="$3"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "版本号必须是 x.y.z：$VERSION" >&2
    exit 65
fi
if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Release ZIP 不存在：$ZIP_PATH" >&2
    exit 66
fi
if [[ ! -d "$TAP_DIR" ]]; then
    echo "Homebrew tap 目录不存在：$TAP_DIR" >&2
    exit 66
fi

CASK_PATH="$TAP_DIR/Casks/guanlan.rb"
if [[ ! -f "$CASK_PATH" ]]; then
    echo "未找到 cask：$CASK_PATH" >&2
    exit 66
fi
RESOLVED_CASK="$(realpath "$CASK_PATH")"
EXPECTED_CASK="$(realpath "$TAP_DIR")/Casks/guanlan.rb"
if [[ "$RESOLVED_CASK" != "$EXPECTED_CASK" ]]; then
    echo "拒绝修改预期之外的 cask 路径：$RESOLVED_CASK" >&2
    exit 67
fi

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
export VERSION SHA256 RESOLVED_CASK

python3 - <<'PY'
import os
import pathlib
import re

path = pathlib.Path(os.environ["RESOLVED_CASK"])
version = os.environ["VERSION"]
sha256 = os.environ["SHA256"]
text = path.read_text(encoding="utf-8")
text, version_count = re.subn(
    r'  version "[^"]+"',
    f'  version "{version}"',
    text,
    count=1,
)
text, sha_count = re.subn(
    r'  sha256 "[0-9a-f]{64}"',
    f'  sha256 "{sha256}"',
    text,
    count=1,
)
if version_count != 1 or sha_count != 1:
    raise SystemExit(f"无法唯一更新 version/sha256：{path}")
path.write_text(text, encoding="utf-8")
print(f"已更新 {path}：version={version}, sha256={sha256}")
PY

brew style "$RESOLVED_CASK"
