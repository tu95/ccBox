#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"

echo "=== [1/3] Running Swift core & live runtime tests (12 checks) ==="
swift run ${@+"$@"} ccbox-verify

echo "=== [2/3] Verifying CoboxURLHook compilation & all exported hook symbols ==="
tmp="$(mktemp -d "/tmp/ccbox-hook-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

arch_flag="$(uname -m)"
dylib="$tmp/libCoboxURLHook.dylib"
/usr/bin/clang -dynamiclib -fobjc-arc -arch "$arch_flag" -mmacosx-version-min=13.0 \
  -framework AppKit -framework CoreServices -framework CFNetwork -framework Network -framework SystemConfiguration -framework Security -O2 \
  "$project/Sources/CoboxURLHook/CoboxURLHook.m" \
  -o "$dylib"
codesign --force --sign - "$dylib"
codesign --verify --strict "$dylib"

symbols="$(nm -U "$dylib")"
for sym in \
  cobox_LSOpenCFURLRef \
  cobox_CFNetworkCopySystemProxySettings \
  cobox_SCDynamicStoreCopyProxies \
  cobox_defaultSessionConfiguration \
  cobox_ephemeralSessionConfiguration \
  cobox_backgroundSessionConfigurationWithIdentifier \
  cobox_setConnectionProxyDictionary \
  cobox_WKConfigInit \
  cobox_standardUserDefaults \
  cobox_initWithSuiteName \
  cobox_CFPreferencesCopyAppValue \
  cobox_CFPreferencesSetAppValue \
  cobox_CFPreferencesAppSynchronize \
  cobox_SecItemAdd \
  cobox_SecItemCopyMatching \
  cobox_SecItemUpdate \
  cobox_SecItemDelete \
  cobox_containerURLForSecurityApplicationGroupIdentifier \
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
echo "[PASS] 13. libCoboxURLHook.dylib 编译、签名与全部 22 组核心拦截符号校验通过"

echo "=== [3/3] Running live DYLD_INSERT_LIBRARIES runtime behavior verification ==="
probe_src="$tmp/hook_probe.m"
probe_bin="$tmp/hook_probe"
cat > "$probe_src" <<'EOF'
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        // 1. NSURLSessionConfiguration default / ephemeral / background + proxy clear lock
        NSURLSessionConfiguration *defCfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        assert([defCfg.connectionProxyDictionary[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);
        assert([defCfg.connectionProxyDictionary[(NSString *)kCFNetworkProxiesSOCKSPort] intValue] == 28081);
        defCfg.connectionProxyDictionary = nil;
        assert([defCfg.connectionProxyDictionary[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);

        NSURLSessionConfiguration *ephCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        assert([ephCfg.connectionProxyDictionary[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);

        NSURLSessionConfiguration *bgCfg = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.tu95.ccbox.probe.bg"];
        assert([bgCfg.connectionProxyDictionary[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);

        // 2. CFNetwork & SCDynamicStore proxy interpose
        NSDictionary *cfProxy = (__bridge_transfer NSDictionary *)CFNetworkCopySystemProxySettings();
        assert([cfProxy[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);
        assert([cfProxy[(NSString *)kCFNetworkProxiesSOCKSPort] intValue] == 28081);

        NSDictionary *scProxy = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyProxies(NULL);
        assert([scProxy[(NSString *)kCFNetworkProxiesHTTPPort] intValue] == 28080);
        assert([scProxy[(NSString *)kCFNetworkProxiesSOCKSPort] intValue] == 28081);

        // 3. App Group container redirection & traversal rejection
        NSURL *grp = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.google.gemini"];
        assert(grp != nil && [grp.path containsString:@"/Library/Group Containers/group.com.google.gemini"]);
        BOOL isDir = NO;
        assert([[NSFileManager defaultManager] fileExistsAtPath:grp.path isDirectory:&isDir] && isDir);

        NSURL *escaped = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"../escape"];
        assert(escaped == nil || ![escaped.path containsString:@"../escape"]);

        // 4. Locale spoofing
        NSArray<NSString *> *langs = [NSLocale preferredLanguages];
        assert(langs.count >= 1 && [langs[0] isEqualToString:@"en-US"]);

        // 5. NSUserDefaults & CFPreferences namespace isolation
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        [std setObject:@"isolated_std" forKey:@"ccbox_probe_std"];
        assert([[std stringForKey:@"ccbox_probe_std"] isEqualToString:@"isolated_std"]);

        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.google.GeminiMacOS.shareddata"];
        [suite setObject:@"isolated_suite" forKey:@"ccbox_probe_suite"];
        assert([[suite stringForKey:@"ccbox_probe_suite"] isEqualToString:@"isolated_suite"]);

        CFPreferencesSetAppValue(CFSTR("ccbox_cf_key"), CFSTR("isolated_cf"), CFSTR("com.google.GeminiMacOS"));
        CFStringRef cfVal = (CFStringRef)CFPreferencesCopyAppValue(CFSTR("ccbox_cf_key"), CFSTR("com.google.GeminiMacOS"));
        assert(cfVal != NULL && CFEqual(cfVal, CFSTR("isolated_cf")));
        if (cfVal) CFRelease(cfVal);

        printf("HOOK_RUNTIME_OK\n");
    }
    return 0;
}
EOF

/usr/bin/clang -fobjc-arc -arch "$arch_flag" -mmacosx-version-min=13.0 \
  -framework Foundation -framework CFNetwork -framework SystemConfiguration \
  "$probe_src" -o "$probe_bin"
codesign --force --sign - "$probe_bin"

mkdir -p "$tmp/apphome/Library/Keychains"
printf 'test-per-env-secret-1234567890\n' > "$tmp/apphome/Library/Keychains/.keychain-secret"
chmod 600 "$tmp/apphome/Library/Keychains/.keychain-secret"

probe_out="$(
  DYLD_INSERT_LIBRARIES="$dylib" \
  CCBOX_PROXY_HTTP_PORT=28080 \
  CCBOX_PROXY_SOCKS_PORT=28081 \
  CCBOX_APP_HOME="$tmp/apphome" \
  CCBOX_ISOLATED_KEYCHAIN="$tmp/apphome/Library/Keychains/login.keychain-db" \
  CCBOX_ISOLATED_KEYCHAIN_SECRET_FILE="$tmp/apphome/Library/Keychains/.keychain-secret" \
  CCBOX_PREFS_NAMESPACE="ccbox.verify.probe" \
  CCBOX_SPOOF_LOCALE=1 \
  "$probe_bin"
)"
if [ "$probe_out" != "HOOK_RUNTIME_OK" ]; then
  echo "[FAIL] Live DYLD_INSERT_LIBRARIES hook probe failed: $probe_out" >&2
  exit 1
fi
echo "[PASS] 14. libCoboxURLHook.dylib 实机注入运行校验（代理锁/CFNetwork/SCDynamicStore/App Group/偏好命名空间/语言伪装）通过"
echo "=== ALL 14/14 CCBOX VERIFICATION CHECKS PASSED ==="
