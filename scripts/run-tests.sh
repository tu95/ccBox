#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"

echo "=== [1/2] Running Swift core & live runtime tests (10 checks) ==="
swift run "$@" ccbox-verify

echo "=== [2/2] Verifying CoboxURLHook compilation & all exported hook symbols ==="
tmp="$(mktemp -d "/tmp/ccbox-hook-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

arch_flag="$(uname -m)"
dylib="$tmp/libCoboxURLHook.dylib"
/usr/bin/clang -dynamiclib -fobjc-arc -arch "$arch_flag" -mmacosx-version-min=13.0 \
  -framework AppKit -framework CoreServices -framework CFNetwork -framework Network -O2 \
  "$project/Sources/CoboxURLHook/CoboxURLHook.m" \
  -o "$dylib"
codesign --force --sign - "$dylib"
codesign --verify --strict "$dylib"

symbols="$(nm -U "$dylib")"
for sym in \
  cobox_LSOpenCFURLRef \
  cobox_CFNetworkCopySystemProxySettings \
  cobox_defaultSessionConfiguration \
  cobox_ephemeralSessionConfiguration \
  cobox_WKConfigInit \
  cobox_preferredLanguages \
  CoboxPanelDelegateGuard \
  cobox_runModal \
  cobox_URLs
do
  if ! printf '%s\n' "$symbols" | grep -q "$sym"; then
    echo "[FAIL] Missing required isolation hook symbol: $sym" >&2
    exit 1
  fi
done
echo "[PASS] 11. libCoboxURLHook.dylib 编译、签名与全部 9 组核心拦截符号校验通过"
echo "=== ALL 11/11 CCBOX VERIFICATION CHECKS PASSED ==="
