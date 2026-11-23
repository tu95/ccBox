#import <AppKit/AppKit.h>
#import <CFNetwork/CFNetwork.h>
#import <CoreServices/CoreServices.h>
#import <Network/Network.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

// MARK: - Helpers

static int coboxEnvPort(const char *name) {
    const char *val = getenv(name);
    if (!val || val[0] == '\0') return 0;
    int port = atoi(val);
    return (port > 0 && port <= 65535) ? port : 0;
}

static NSDictionary *coboxProxyDictionary(void) {
    int httpPort = coboxEnvPort("CCBOX_PROXY_HTTP_PORT");
    int socksPort = coboxEnvPort("CCBOX_PROXY_SOCKS_PORT");
    if (httpPort == 0 && socksPort == 0) return nil;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (httpPort > 0) {
        dict[(NSString *)kCFNetworkProxiesHTTPEnable] = @YES;
        dict[(NSString *)kCFNetworkProxiesHTTPProxy] = @"127.0.0.1";
        dict[(NSString *)kCFNetworkProxiesHTTPPort] = @(httpPort);
        dict[(NSString *)kCFNetworkProxiesHTTPSEnable] = @YES;
        dict[(NSString *)kCFNetworkProxiesHTTPSProxy] = @"127.0.0.1";
        dict[(NSString *)kCFNetworkProxiesHTTPSPort] = @(httpPort);
    }
    if (socksPort > 0) {
        dict[(NSString *)kCFNetworkProxiesSOCKSEnable] = @YES;
        dict[(NSString *)kCFNetworkProxiesSOCKSProxy] = @"127.0.0.1";
        dict[(NSString *)kCFNetworkProxiesSOCKSPort] = @(socksPort);
    }
    dict[(NSString *)kCFNetworkProxiesExceptionsList] = @[@"localhost", @"127.0.0.1", @"::1"];
    dict[(NSString *)kCFNetworkProxiesExcludeSimpleHostnames] = @YES;
    return [dict copy];
}

static NSArray<NSString *> *coboxAllowedPaths(void) {
    static NSArray<NSString *> *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *env = getenv("CCBOX_ALLOWED_PATHS");
        if (!env || env[0] == '\0') return;
        NSString *raw = [NSString stringWithUTF8String:env];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *part in [raw componentsSeparatedByString:@":"]) {
            if (part.length == 0) continue;
            NSString *resolved = [[NSURL fileURLWithPath:part] URLByResolvingSymlinksInPath].path;
            if (resolved.length > 0) {
                [paths addObject:resolved];
            }
        }
        if (paths.count > 0) {
            cached = [paths copy];
        }
    });
    return cached;
}

static NSString *coboxNormalizedPath(NSURL *url) {
    if (!url || !url.isFileURL) return nil;
    NSString *resolved = [url URLByResolvingSymlinksInPath].path;
    return resolved ?: url.path;
}

static BOOL coboxPathIsInsideAllowed(NSString *path, NSArray<NSString *> *allowed) {
    if (!path || allowed.count == 0) return YES;
    for (NSString *prefix in allowed) {
        if ([path isEqualToString:prefix]) return YES;
        NSString *withSlash = [prefix hasSuffix:@"/"] ? prefix : [prefix stringByAppendingString:@"/"];
        if ([path hasPrefix:withSlash]) return YES;
    }
    return NO;
}

static BOOL coboxPathIsAncestorOfAllowed(NSString *path, NSArray<NSString *> *allowed) {
    if (!path || allowed.count == 0) return YES;
    NSString *withSlash = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    for (NSString *prefix in allowed) {
        if ([prefix hasPrefix:withSlash]) return YES;
    }
    return NO;
}

// MARK: - 1. Browser URL Bridge Redirection

static BOOL coboxShouldInterceptURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }
    return url.host.length > 0;
}

static BOOL coboxForwardURL(NSURL *url) {
    if (!coboxShouldInterceptURL(url)) return NO;

    const char *portEnv = getenv("CLAUDE_SANDBOX_BROWSER_PORT");
    const char *tokenEnv = getenv("CLAUDE_SANDBOX_BROWSER_TOKEN");
    if (!portEnv || !tokenEnv || portEnv[0] == '\0' || tokenEnv[0] == '\0') {
        return NO;
    }
    int port = atoi(portEnv);
    if (port <= 0 || port > 65535) return NO;

    NSString *urlString = url.absoluteString;
    if (urlString.length == 0 || urlString.length > 3500) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }

    NSString *payload = [NSString stringWithFormat:@"%s %@\n", tokenEnv, urlString];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t remaining = data.length;
    size_t offset = 0;
    while (remaining > 0) {
        ssize_t n = write(fd, bytes + offset, remaining);
        if (n <= 0) {
            close(fd);
            return NO;
        }
        offset += (size_t)n;
        remaining -= (size_t)n;
    }

    char reply[16];
    ssize_t got = read(fd, reply, sizeof(reply) - 1);
    close(fd);
    return (got >= 2 && reply[0] == 'O' && reply[1] == 'K');
}

@implementation NSWorkspace (CoboxURLHook)

- (BOOL)cobox_openURL:(NSURL *)url {
    if (coboxForwardURL(url)) return YES;
    return [self cobox_openURL:url];
}

- (void)cobox_openURL:(NSURL *)url
        configuration:(NSWorkspaceOpenConfiguration *)configuration
    completionHandler:(void (^)(NSRunningApplication * _Nullable app, NSError * _Nullable error))completionHandler {
    if (coboxForwardURL(url)) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil); });
        }
        return;
    }
    [self cobox_openURL:url configuration:configuration completionHandler:completionHandler];
}

- (void)cobox_openURLs:(NSArray<NSURL *> *)urls
withApplicationAtURL:(NSURL *)applicationURL
       configuration:(NSWorkspaceOpenConfiguration *)configuration
   completionHandler:(void (^)(NSRunningApplication * _Nullable app, NSError * _Nullable error))completionHandler {
    BOOL handledAny = NO;
    NSMutableArray<NSURL *> *passthrough = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (coboxForwardURL(url)) handledAny = YES;
        else [passthrough addObject:url];
    }
    if (passthrough.count == 0 && handledAny) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil); });
        }
        return;
    }
    [self cobox_openURLs:(handledAny ? passthrough : urls)
    withApplicationAtURL:applicationURL
           configuration:configuration
       completionHandler:completionHandler];
}

- (BOOL)cobox_openURLs:(NSArray<NSURL *> *)urls
withAppBundleIdentifier:(NSString *)bundleIdentifier
               options:(NSWorkspaceLaunchOptions)options
additionalEventParamDescriptor:(NSAppleEventDescriptor *)descriptor
     launchIdentifiers:(NSArray<NSNumber *> * _Nullable * _Nullable)identifiers {
    BOOL handledAny = NO;
    NSMutableArray<NSURL *> *passthrough = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (coboxForwardURL(url)) handledAny = YES;
        else [passthrough addObject:url];
    }
    if (passthrough.count == 0 && handledAny) return YES;
    return [self cobox_openURLs:(handledAny ? passthrough : urls)
        withAppBundleIdentifier:bundleIdentifier
                        options:options
 additionalEventParamDescriptor:descriptor
              launchIdentifiers:identifiers];
}

@end

// MARK: - 2. Native Network Proxy Injection (NSURLSession + CFNetwork + WKWebView)

@implementation NSURLSessionConfiguration (CoboxProxyHook)

+ (NSURLSessionConfiguration *)cobox_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self cobox_defaultSessionConfiguration];
    NSDictionary *proxy = coboxProxyDictionary();
    if (proxy) {
        config.connectionProxyDictionary = proxy;
    }
    return config;
}

+ (NSURLSessionConfiguration *)cobox_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self cobox_ephemeralSessionConfiguration];
    NSDictionary *proxy = coboxProxyDictionary();
    if (proxy) {
        config.connectionProxyDictionary = proxy;
    }
    return config;
}

@end

static void coboxApplyWKWebViewProxyIfAvailable(id wkConfig) {
    if (!wkConfig) return;
    int httpPort = coboxEnvPort("CCBOX_PROXY_HTTP_PORT");
    if (httpPort <= 0) return;
    if (@available(macOS 14.0, *)) {
        SEL storeSel = NSSelectorFromString(@"websiteDataStore");
        SEL setProxiesSel = NSSelectorFromString(@"setProxyConfigurations:");
        if (![wkConfig respondsToSelector:storeSel]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id store = [wkConfig performSelector:storeSel];
        if (store && [store respondsToSelector:setProxiesSel]) {
            char portBuf[16];
            snprintf(portBuf, sizeof(portBuf), "%d", httpPort);
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portBuf);
            if (endpoint) {
                nw_proxy_config_t proxyCfg = nw_proxy_config_create_http_connect(endpoint, NULL);
                if (proxyCfg) {
                    NSArray *configs = @[proxyCfg];
                    [store performSelector:setProxiesSel withObject:configs];
                }
            }
        }
#pragma clang diagnostic pop
    }
}

static id (*coboxOrigWKConfigInit)(id, SEL) = NULL;
static id cobox_WKConfigInit(id self, SEL _cmd) {
    id instance = coboxOrigWKConfigInit ? coboxOrigWKConfigInit(self, _cmd) : self;
    coboxApplyWKWebViewProxyIfAvailable(instance);
    return instance;
}

// MARK: - 3. Locale Spoofing (NSLocale)

@implementation NSLocale (CoboxLocaleHook)

+ (NSArray<NSString *> *)cobox_preferredLanguages {
    const char *spoof = getenv("CCBOX_SPOOF_LOCALE");
    if (spoof && spoof[0] == '1') {
        return @[@"en-US", @"en"];
    }
    return [self cobox_preferredLanguages];
}

@end

// MARK: - 4. File Picker Sandbox Path Enforcement (NSOpenPanel / NSSavePanel)

static const void *kCoboxPanelGuardKey = &kCoboxPanelGuardKey;

@interface CoboxPanelDelegateGuard : NSObject <NSOpenSavePanelDelegate>
@property (nonatomic, weak) id<NSOpenSavePanelDelegate> originalDelegate;
@end

@implementation CoboxPanelDelegateGuard

- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url {
    NSArray<NSString *> *allowed = coboxAllowedPaths();
    if (allowed.count > 0 && url.isFileURL) {
        NSString *path = coboxNormalizedPath(url);
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
        BOOL ok = coboxPathIsInsideAllowed(path, allowed) || (isDir && coboxPathIsAncestorOfAllowed(path, allowed));
        if (!ok) return NO;
    }
    if ([self.originalDelegate respondsToSelector:@selector(panel:shouldEnableURL:)]) {
        return [self.originalDelegate panel:sender shouldEnableURL:url];
    }
    return YES;
}

- (BOOL)panel:(id)sender validateURL:(NSURL *)url error:(NSError * _Nullable *)outError {
    NSArray<NSString *> *allowed = coboxAllowedPaths();
    if (allowed.count > 0 && url.isFileURL) {
        NSString *path = coboxNormalizedPath(url);
        if (!coboxPathIsInsideAllowed(path, allowed)) {
            if (outError) {
                *outError = [NSError errorWithDomain:@"com.tu95.ccbox.sandbox"
                                                code:1
                                            userInfo:@{
                    NSLocalizedDescriptionKey: @"禁止访问隔离区外的文件",
                    NSLocalizedRecoverySuggestionErrorKey: @"当前环境已启用纯隔离模式，只允许加载沙箱工作区内的文件。"
                }];
            }
            return NO;
        }
    }
    if ([self.originalDelegate respondsToSelector:@selector(panel:validateURL:error:)]) {
        return [self.originalDelegate panel:sender validateURL:url error:outError];
    }
    return YES;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end

static void coboxGuardSavePanel(NSSavePanel *panel) {
    if (!panel) return;
    const char *wsEnv = getenv("CCBOX_SANDBOX_WORKSPACE");
    if (wsEnv && wsEnv[0] != '\0') {
        NSURL *wsURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:wsEnv] isDirectory:YES];
        NSArray<NSString *> *allowed = coboxAllowedPaths();
        if (!panel.directoryURL || (allowed.count > 0 && !coboxPathIsInsideAllowed(coboxNormalizedPath(panel.directoryURL), allowed))) {
            panel.directoryURL = wsURL;
        }
    }
    if (coboxAllowedPaths().count == 0) return;

    CoboxPanelDelegateGuard *guard = objc_getAssociatedObject(panel, kCoboxPanelGuardKey);
    if (!guard) {
        guard = [[CoboxPanelDelegateGuard alloc] init];
        if (panel.delegate && panel.delegate != guard) {
            guard.originalDelegate = panel.delegate;
        }
        objc_setAssociatedObject(panel, kCoboxPanelGuardKey, guard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        panel.delegate = guard;
    }
}

@implementation NSSavePanel (CoboxSandboxGuard)

- (NSModalResponse)cobox_runModal {
    coboxGuardSavePanel(self);
    return [self cobox_runModal];
}

- (void)cobox_beginWithCompletionHandler:(void (^)(NSModalResponse result))handler {
    coboxGuardSavePanel(self);
    [self cobox_beginWithCompletionHandler:handler];
}

- (void)cobox_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse result))handler {
    coboxGuardSavePanel(self);
    [self cobox_beginSheetModalForWindow:sheetWindow completionHandler:handler];
}

- (NSURL *)cobox_URL {
    NSURL *url = [self cobox_URL];
    NSArray<NSString *> *allowed = coboxAllowedPaths();
    if (url && allowed.count > 0 && url.isFileURL && !coboxPathIsInsideAllowed(coboxNormalizedPath(url), allowed)) {
        return nil;
    }
    return url;
}

@end

@implementation NSOpenPanel (CoboxSandboxGuard)

- (NSArray<NSURL *> *)cobox_URLs {
    NSArray<NSURL *> *urls = [self cobox_URLs];
    NSArray<NSString *> *allowed = coboxAllowedPaths();
    if (allowed.count == 0 || urls.count == 0) return urls;
    NSMutableArray<NSURL *> *filtered = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (!url.isFileURL || coboxPathIsInsideAllowed(coboxNormalizedPath(url), allowed)) {
            [filtered addObject:url];
        }
    }
    return filtered;
}

@end

// MARK: - Swizzle & Interpose Installation

static void coboxSwizzleInstance(Class cls, SEL originalSel, SEL swizzledSel) {
    Method original = class_getInstanceMethod(cls, originalSel);
    Method swizzled = class_getInstanceMethod(cls, swizzledSel);
    if (original && swizzled) {
        method_exchangeImplementations(original, swizzled);
    }
}

static void coboxSwizzleClass(Class cls, SEL originalSel, SEL swizzledSel) {
    Method original = class_getClassMethod(cls, originalSel);
    Method swizzled = class_getClassMethod(cls, swizzledSel);
    if (original && swizzled) {
        method_exchangeImplementations(original, swizzled);
    }
}

__attribute__((constructor))
static void coboxInstallHooks(void) {
    // 1. Browser URL redirection
    if (coboxEnvPort("CLAUDE_SANDBOX_BROWSER_PORT") > 0) {
        Class ws = [NSWorkspace class];
        coboxSwizzleInstance(ws, @selector(openURL:), @selector(cobox_openURL:));
        coboxSwizzleInstance(ws, @selector(openURL:configuration:completionHandler:),
                             @selector(cobox_openURL:configuration:completionHandler:));
        coboxSwizzleInstance(ws, @selector(openURLs:withApplicationAtURL:configuration:completionHandler:),
                             @selector(cobox_openURLs:withApplicationAtURL:configuration:completionHandler:));
        coboxSwizzleInstance(ws, @selector(openURLs:withAppBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifiers:),
                             @selector(cobox_openURLs:withAppBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifiers:));
    }

    // 2. Native NSURLSession & WKWebView proxy injection
    if (coboxEnvPort("CCBOX_PROXY_HTTP_PORT") > 0 || coboxEnvPort("CCBOX_PROXY_SOCKS_PORT") > 0) {
        Class sessionCfg = [NSURLSessionConfiguration class];
        coboxSwizzleClass(sessionCfg, @selector(defaultSessionConfiguration), @selector(cobox_defaultSessionConfiguration));
        coboxSwizzleClass(sessionCfg, @selector(ephemeralSessionConfiguration), @selector(cobox_ephemeralSessionConfiguration));

        Class wkConfigClass = NSClassFromString(@"WKWebViewConfiguration");
        if (wkConfigClass) {
            Method initMethod = class_getInstanceMethod(wkConfigClass, @selector(init));
            if (initMethod) {
                coboxOrigWKConfigInit = (id (*)(id, SEL))method_getImplementation(initMethod);
                method_setImplementation(initMethod, (IMP)cobox_WKConfigInit);
            }
        }
    }

    // 3. Locale spoofing
    const char *spoof = getenv("CCBOX_SPOOF_LOCALE");
    if (spoof && spoof[0] == '1') {
        coboxSwizzleClass([NSLocale class], @selector(preferredLanguages), @selector(cobox_preferredLanguages));
    }

    // 4. File picker path restriction
    if (getenv("CCBOX_SANDBOX_WORKSPACE") != NULL || coboxAllowedPaths().count > 0) {
        Class savePanel = [NSSavePanel class];
        coboxSwizzleInstance(savePanel, @selector(runModal), @selector(cobox_runModal));
        coboxSwizzleInstance(savePanel, @selector(beginWithCompletionHandler:), @selector(cobox_beginWithCompletionHandler:));
        coboxSwizzleInstance(savePanel, @selector(beginSheetModalForWindow:completionHandler:), @selector(cobox_beginSheetModalForWindow:completionHandler:));
        coboxSwizzleInstance(savePanel, @selector(URL), @selector(cobox_URL));

        Class openPanel = [NSOpenPanel class];
        coboxSwizzleInstance(openPanel, @selector(URLs), @selector(cobox_URLs));
    }
}

static OSStatus cobox_LSOpenCFURLRef(CFURLRef inURL, CFURLRef *outLaunchedURL) {
    NSURL *nsURL = (__bridge NSURL *)inURL;
    if (coboxForwardURL(nsURL)) {
        if (outLaunchedURL) *outLaunchedURL = NULL;
        return noErr;
    }
    return LSOpenCFURLRef(inURL, outLaunchedURL);
}

static CFDictionaryRef cobox_CFNetworkCopySystemProxySettings(void) {
    NSDictionary *proxy = coboxProxyDictionary();
    if (proxy) {
        return (__bridge_retained CFDictionaryRef)proxy;
    }
    return CFNetworkCopySystemProxySettings();
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

DYLD_INTERPOSE(cobox_LSOpenCFURLRef, LSOpenCFURLRef)
DYLD_INTERPOSE(cobox_CFNetworkCopySystemProxySettings, CFNetworkCopySystemProxySettings)
