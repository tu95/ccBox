#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
output="$project/dist"
app_name="${CCBOX_APP_NAME:-ccBox.app}"
cd "$project"

if [ -f "$project/scripts/icon.png" ]; then
  icon_tmp="$(mktemp -d "/tmp/ccbox-icon.XXXXXX")"
  trap 'rm -rf "$icon_tmp"' EXIT
  python3 - "$project/scripts/icon.png" "$icon_tmp" "$project/scripts/AppIcon.icns" <<'PY'
import os, struct, subprocess, sys
src, tmp, dst = sys.argv[1], sys.argv[2], sys.argv[3]
specs = [
    (b"icp4", 16), (b"icp5", 32), (b"ic11", 32), (b"ic12", 64),
    (b"ic07", 128), (b"ic13", 256), (b"ic08", 256), (b"ic14", 512),
    (b"ic09", 512), (b"ic10", 1024),
]
chunks = []
cache = {}
for tag, size in specs:
    if size not in cache:
        out = os.path.join(tmp, f"{size}.png")
        subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-z", str(size), str(size), src, "--out", out],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cache[size] = open(out, "rb").read()
    data = cache[size]
    chunks.append(tag + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
with open(dst, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
  rm -rf "$icon_tmp"
fi

swift build -c release "$@"
build="$(swift build -c release --show-bin-path "$@")"

mkdir -p "$output"
staging="$(mktemp -d "$output/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/ClaudeSandboxApp" "$app/Contents/MacOS/"
cp -R "$build/ClaudeSandbox_ClaudeSandboxCore.bundle" "$build/ClaudeSandbox_ClaudeSandboxApp.bundle" "$app/Contents/Resources/"
cp "$project/scripts/Info.plist" "$app/Contents/Info.plist"
if [ -f "$project/scripts/AppIcon.icns" ]; then
  cp "$project/scripts/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
rm -rf "$output/$app_name"
mv "$app" "$output/$app_name"
printf '%s\n' "$output/$app_name"
