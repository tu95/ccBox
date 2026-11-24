#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
output="$project/dist"
app_name="${CCBOX_APP_NAME:-ccbox.app}"
cd "$project"

skip_tests=0
swift_args=()
for arg in "$@"; do
  if [ "$arg" = "--skip-tests" ]; then
    skip_tests=1
  else
    swift_args+=("$arg")
  fi
done

if [ "$skip_tests" -eq 0 ]; then
  echo ">>> Running full ccbox isolation verification suite before release build..."
  "$project/scripts/run-tests.sh" ${swift_args[@]+"${swift_args[@]}"}
fi

if [ -f "$project/scripts/icon.png" ] && { [ ! -f "$project/scripts/AppIcon.icns" ] || [ "$project/scripts/icon.png" -nt "$project/scripts/AppIcon.icns" ]; }; then
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

swift build -c release ${swift_args[@]+"${swift_args[@]}"}
build="$(swift build -c release --show-bin-path ${swift_args[@]+"${swift_args[@]}"})"

mkdir -p "$output"
staging="$(mktemp -d "$output/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/CCBoxApp" "$app/Contents/MacOS/"
cp "$build/CCBoxNestedLauncher" "$app/Contents/Resources/"
cp -R "$build/CCBox_CCBoxCore.bundle" "$build/CCBox_CCBoxApp.bundle" "$app/Contents/Resources/"
cp "$project/scripts/Info.plist" "$app/Contents/Info.plist"
if [ -f "$project/scripts/AppIcon.icns" ]; then
  cp "$project/scripts/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
sign_identity="${CCBOX_CODESIGN_IDENTITY:--}"
network_filter="${CCBOX_ENABLE_NETWORK_FILTER:-0}"
if [ "$network_filter" = "1" ]; then
  app_profile="${CCBOX_APP_PROVISIONING_PROFILE:-}"
  extension_profile="${CCBOX_NETWORK_FILTER_PROVISIONING_PROFILE:-}"
  if [ "$sign_identity" = "-" ] || [ ! -f "$app_profile" ] || [ ! -f "$extension_profile" ]; then
    echo "NetworkExtension packaging requires CCBOX_CODESIGN_IDENTITY, CCBOX_APP_PROVISIONING_PROFILE, and CCBOX_NETWORK_FILTER_PROVISIONING_PROFILE." >&2
    exit 1
  fi
  cp "$app_profile" "$app/Contents/embedded.provisionprofile"
  network_extension="$app/Contents/Library/SystemExtensions/com.tu95.ccbox.NetworkFilter.systemExtension"
  mkdir -p "$network_extension/Contents/MacOS"
  cp "$build/CCBoxNetworkFilter" "$network_extension/Contents/MacOS/"
  cp "$project/scripts/NetworkFilterInfo.plist" "$network_extension/Contents/Info.plist"
  cp "$extension_profile" "$network_extension/Contents/embedded.provisionprofile"
  codesign --force --sign "$sign_identity" \
    --entitlements "$project/scripts/CCBoxNetworkFilter.entitlements" "$network_extension"
  codesign --verify --strict "$network_extension"
fi
codesign --force --sign "$sign_identity" "$app/Contents/Resources/CCBoxNestedLauncher"
if [ -f "$project/Sources/CoboxURLHook/CoboxURLHook.m" ]; then
  arch_flag="$(uname -m)"
  /usr/bin/clang -dynamiclib -fobjc-arc -arch "$arch_flag" -mmacosx-version-min=13.0 \
    -framework AppKit -framework CoreServices -framework CFNetwork -framework Network -framework SystemConfiguration -framework Security -O2 \
    "$project/Sources/CoboxURLHook/CoboxURLHook.m" \
    -o "$app/Contents/Resources/libCoboxURLHook.dylib"
  codesign --force --sign "$sign_identity" "$app/Contents/Resources/libCoboxURLHook.dylib"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_CFNetworkCopySystemProxySettings"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_SCDynamicStoreCopyProxies"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_CFPreferencesCopyAppValue"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_SecItemAdd"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_SecKeychainFindGenericPassword"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_containerURLForSecurityApplicationGroupIdentifier"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "cobox_LSOpenCFURLRef"
  nm -U "$app/Contents/Resources/libCoboxURLHook.dylib" | grep -q "CoboxPanelDelegateGuard"
fi
if [ "$network_filter" = "1" ]; then
  codesign --force --sign "$sign_identity" --entitlements "$project/scripts/CCBox.entitlements" "$app"
else
  codesign --force --sign "$sign_identity" "$app"
fi
codesign --verify --strict "$app"
rm -rf "$output/$app_name"
mv "$app" "$output/$app_name"
printf '%s\n' "$output/$app_name"
