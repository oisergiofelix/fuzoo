// One-shot diagnostic; shared credentials are read-only and never printed.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonCrypto.h>
#include <sqlite3.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

static BOOL allowKeychainPrompt;
static OSStatus keychainStatus;
static BOOL diagnostic;
static NSString *const authorizationResultPath = @"/private/tmp/fuzoo-usage-authorize-result.json";
static void trace(NSString *stage) { if (diagnostic) fprintf(stderr, "usage-bridge: %s\n", stage.UTF8String); }

@interface UsageTransport : NSObject <NSURLSessionTaskDelegate>
@end
@implementation UsageTransport
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

static void deadline(int sig) {
    (void)sig;
    const char message[] = "{\"state\":\"timeout\"}\n";
    write(STDOUT_FILENO, message, sizeof message - 1);
    _exit(1);
}

static NSDictionary *decode(NSData *data) {
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void inspectKeychainAccess(void) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: @"Claude Safe Storage",
                            (__bridge id)kSecReturnRef: @YES};
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    NSMutableDictionary *output = [@{@"status": @(status)} mutableCopy];
    SecAccessRef access = NULL;
    CFArrayRef list = NULL;
    NSMutableArray *entries = [NSMutableArray new];
    if (item && SecKeychainItemCopyAccess((SecKeychainItemRef)item, &access) == errSecSuccess &&
        SecAccessCopyACLList(access, &list) == errSecSuccess) {
        for (id entry in (__bridge NSArray *)list) {
            SecACLRef acl = (__bridge SecACLRef)entry;
            NSArray *auth = CFBridgingRelease(SecACLCopyAuthorizations(acl));
            if (![auth containsObject:(__bridge NSString *)kSecACLAuthorizationDecrypt]) continue;
            CFArrayRef apps = NULL; CFStringRef description = NULL; SecKeychainPromptSelector selector;
            if (SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess) {
                NSMutableArray *paths = [NSMutableArray new];
                for (id app in (__bridge NSArray *)apps) {
                    CFDataRef data = NULL;
                    if (SecTrustedApplicationCopyData((__bridge SecTrustedApplicationRef)app, &data) == errSecSuccess) {
                        NSData *bytes = CFBridgingRelease(data);
                        NSString *path = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
                        if (path) {
                            path = [path stringByTrimmingCharactersInSet:NSCharacterSet.controlCharacterSet];
                            [paths addObject:path];
                        }
                    }
                }
                [entries addObject:@{@"trusted_applications": paths, @"all_applications": @(apps == NULL)}];
            }
            if (apps) CFRelease(apps);
            if (description) CFRelease(description);
        }
    }
    if (list) CFRelease(list);
    if (access) CFRelease(access);
    if (item) CFRelease(item);
    output[@"decrypt_access"] = entries;
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes, 1, json.length, stdout); puts("");
}
#pragma clang diagnostic pop

static NSData *keychainData(NSString *service) {
    trace([@"keychain: " stringByAppendingString:service]);
    NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: service,
                            (__bridge id)kSecReturnData: @YES} mutableCopy];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    keychainStatus = status;
    if (status != errSecSuccess) return nil;
    return CFBridgingRelease(result);
}

// Chromium macOS v10 cookies: PBKDF2 + AES-CBC. Scope is exactly the
// Claude Desktop database, claude.ai domain, and these two cookie names.
static NSDictionary *desktopClaudeSession(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Claude/Cookies"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 500);
    sqlite3_stmt *stmt = NULL;
    const char *query = "SELECT host_key,name,value,encrypted_value FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('sessionKey','lastActiveOrg')";
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *host = @((const char *)sqlite3_column_text(stmt, 0));
            NSString *name = @((const char *)sqlite3_column_text(stmt, 1));
            NSString *plain = @((const char *)sqlite3_column_text(stmt, 2));
            NSData *encrypted = [NSData dataWithBytes:sqlite3_column_blob(stmt, 3) length:sqlite3_column_bytes(stmt, 3)];
            rows[name] = @{ @"host": host, @"plain": plain, @"encrypted": encrypted };
        }
    }
    sqlite3_finalize(stmt); sqlite3_close(db);
    if (!rows[@"sessionKey"] || !rows[@"lastActiveOrg"]) return nil;
    NSData *secret = keychainData(@"Claude Safe Storage");
    if (!secret.length) return nil;
    unsigned char key[16], iv[16]; memset(iv, ' ', sizeof iv);
    if (CCKeyDerivationPBKDF(kCCPBKDF2, secret.bytes, secret.length, (const unsigned char *)"saltysalt", 9,
                            kCCPRFHmacAlgSHA1, 1003, key, sizeof key) != kCCSuccess) return nil;
    NSMutableDictionary *cookies = [NSMutableDictionary new];
    for (NSString *name in rows) {
        NSDictionary *row = rows[name]; NSString *value = row[@"plain"];
        if (!value.length) {
            NSData *encrypted = row[@"encrypted"];
            if (encrypted.length <= 3 || memcmp(encrypted.bytes, "v10", 3)) return nil;
            NSMutableData *plain = [NSMutableData dataWithLength:encrypted.length + 16]; size_t length = 0;
            if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key, sizeof key, iv,
                        (const char *)encrypted.bytes + 3, encrypted.length - 3, plain.mutableBytes, plain.length, &length) != kCCSuccess) return nil;
            plain.length = length;
            unsigned char hash[CC_SHA256_DIGEST_LENGTH]; NSData *host = [row[@"host"] dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256(host.bytes, (CC_LONG)host.length, hash);
            if (length > sizeof hash && !memcmp(plain.bytes, hash, sizeof hash))
                plain = [[plain subdataWithRange:NSMakeRange(sizeof hash, length - sizeof hash)] mutableCopy];
            value = [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
        }
        if (!value.length || [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
        cookies[name] = value;
    }
    return cookies;
}

static NSDictionary *window(id raw, NSString *percentKey, NSString *resetKey) {
    if (![raw isKindOfClass:NSDictionary.class]) return @{ @"state": @"unavailable" };
    id value = raw[percentKey];
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !isfinite([value doubleValue]) || [value doubleValue] < 0 || [value doubleValue] > 100)
        return @{ @"state": @"unavailable" };
    NSMutableDictionary *out = [@{ @"state": @"ok", @"remaining_percent": @(100 - [value doubleValue]) } mutableCopy];
    id reset = raw[resetKey];
    if ([reset isKindOfClass:NSNumber.class] || [reset isKindOfClass:NSString.class]) out[@"reset_at"] = reset;
    return out;
}

static NSDictionary *usableProvider(NSDictionary *result) {
    // HTTP 200 alone is not a successful connection: we need a real current window.
    NSDictionary *session = result[@"session"];
    return [session[@"state"] isEqual:@"ok"] && session[@"reset_at"] ? result : @{@"state": @"invalid_response"};
}

static NSDictionary *fetch(BOOL claude) {
    trace(claude ? @"Claude credentials" : @"Codex credentials");
    NSDictionary *auth;
    if (claude) {
        auth = decode([NSData dataWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@".claude/.credentials.json"]]);
    } else {
        auth = decode([NSData dataWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@".codex/auth.json"]]);
    }
    NSDictionary *tokens = claude ? auth[@"claudeAiOauth"] : auth[@"tokens"];
    NSString *token = [tokens isKindOfClass:NSDictionary.class] ? tokens[claude ? @"accessToken" : @"access_token"] : nil;
    NSDictionary *cookies = nil;
    BOOL oauth = [token isKindOfClass:NSString.class] && token.length;
    if (!oauth && claude) cookies = desktopClaudeSession();
    if (!oauth && !cookies) return @{ @"state": @"credentials_unavailable", @"keychain_status": @(keychainStatus) };
    NSString *endpoint = claude ? @"https://api.anthropic.com/api/oauth/usage" : @"https://chatgpt.com/backend-api/wham/usage";
    if (cookies) {
        NSString *org = cookies[@"lastActiveOrg"];
        if (![[NSUUID alloc] initWithUUIDString:org]) return @{ @"state": @"invalid_active_organization" };
        endpoint = [NSString stringWithFormat:@"https://claude.ai/api/organizations/%@/usage", org];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    if (oauth) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    else [request setValue:[NSString stringWithFormat:@"sessionKey=%@; lastActiveOrg=%@", cookies[@"sessionKey"], cookies[@"lastActiveOrg"]] forHTTPHeaderField:@"Cookie"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"fuzoo-usage-bridge/experimental" forHTTPHeaderField:@"User-Agent"];
    if (claude && oauth) [request setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    else {
        id account = tokens[@"account_id"];
        if ([account isKindOfClass:NSString.class] && [account length]) [request setValue:account forHTTPHeaderField:@"ChatGPT-Account-Id"];
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    config.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:[UsageTransport new] delegateQueue:nil];
    trace(claude ? @"Claude usage request" : @"Codex usage request");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *out;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error) out = @{ @"state": @"network_error" };
        else if (status != 200) {
            NSMutableDictionary *failure = [@{ @"state": @"http_error", @"http_status": @(status) } mutableCopy];
            NSString *retry = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"];
            if (retry.doubleValue > 0) failure[@"retry_after_seconds"] = @(ceil(retry.doubleValue));
            out = failure;
        }
        else {
            NSDictionary *json = decode(data);
            if (!json) out = @{ @"state": @"invalid_response" };
            else if (claude) out = @{ @"state": @"ok", @"session": window(json[@"five_hour"], @"utilization", @"resets_at"),
                                     @"weekly": window(json[@"seven_day"], @"utilization", @"resets_at") };
            else {
                id limits = json[@"rate_limit"];
                if (![limits isKindOfClass:NSDictionary.class]) limits = @{};
                out = @{ @"state": @"ok", @"session": window(limits[@"primary_window"], @"used_percent", @"reset_at"),
                         @"weekly": window(limits[@"secondary_window"], @"used_percent", @"reset_at") };
            }
        }
        if ([out[@"state"] isEqual:@"ok"]) out = usableProvider(out);
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
        [task cancel]; [session invalidateAndCancel];
        return @{ @"state": @"timeout" };
    }
    [session finishTasksAndInvalidate];
    trace(claude ? @"Claude response complete" : @"Codex response complete");
    return out ?: @{ @"state": @"unavailable" };
}

static void selfTest(void) {
    NSCAssert([window(nil, @"used", @"reset")[@"state"] isEqual:@"unavailable"], @"Missing is unknown");
    for (id invalid in @[@YES, @"0", @(-1), @101, NSNull.null])
        NSCAssert([window(@{@"used":invalid}, @"used", @"reset")[@"state"] isEqual:@"unavailable"], @"Invalid is unknown");
    NSCAssert([window(@{@"used":@0}, @"used", @"reset")[@"remaining_percent"] isEqual:@100], @"Unused means 100 remaining");
    NSCAssert([window(@{@"used":@100}, @"used", @"reset")[@"remaining_percent"] isEqual:@0], @"Exhausted means zero remaining");
    NSCAssert([window(@{@"used":@18, @"reset":@123}, @"used", @"reset")[@"reset_at"] isEqual:@123], @"Preserve reset");
    puts("usage-bridge: normalization checks passed");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--self-test")) { selfTest(); return 0; }
        if (argc == 2 && !strcmp(argv[1], "--inspect-keychain-access")) { inspectKeychainAccess(); return 0; }
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--allow-keychain-prompt")) allowKeychainPrompt = YES;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--diagnostic")) diagnostic = YES;
        BOOL background = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--background")) background = YES;
        NSString *provider;
        for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "--provider")) provider = @(argv[i + 1]);
        if (provider && ![provider isEqual:@"codex"] && ![provider isEqual:@"claude"]) return 2;
        BOOL agent = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--agent")) agent = YES;
        BOOL authorize = !background && !agent && [NSBundle.mainBundle.bundleIdentifier isEqual:@"io.github.oisergiofelix.fuzoo.usage-bridge"];
        if (authorize) allowKeychainPrompt = YES;
        // Also covers legacy Keychain ACL dialogs beyond LAContext policy.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        SecKeychainSetUserInteractionAllowed(allowKeychainPrompt);
#pragma clang diagnostic pop
        if (authorize || agent) {
            NSApplication *app = NSApplication.sharedApplication;
            app.activationPolicy = NSApplicationActivationPolicyAccessory;
            if (authorize) [app activateIgnoringOtherApps:YES];
            if (agent) { signal(SIGALRM, deadline); alarm(45); }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                    NSDictionary *result = agent ? @{ @"codex": fetch(NO), @"claude": fetch(YES),
                                                       @"captured_at": @((long long)NSDate.date.timeIntervalSince1970),
                                                       @"elapsed_ms": @((long long)((CFAbsoluteTimeGetCurrent() - start) * 1000)) } : fetch(YES);
                    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
                    [json writeToFile:agent ? @"/private/tmp/fuzoo-usage-background-result.json" : authorizationResultPath options:NSDataWritingAtomic error:NULL];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (agent) { alarm(0); [app terminate:nil]; return; }
                        NSAlert *alert = [NSAlert new];
                        BOOL ok = [result[@"state"] isEqual:@"ok"];
                        alert.messageText = ok ? @"Claude conectado" : @"Não foi possível conectar o Claude";
                        alert.informativeText = ok ? @"A consulta de limites funcionou. Nenhuma credencial foi salva pelo conector."
                                                   : [NSString stringWithFormat:@"Estado: %@. O acesso pode ser negado pelo Chaves ou pelo serviço.", result[@"state"]];
                        [app activateIgnoringOtherApps:YES];
                        [alert runModal];
                        [app terminate:nil];
                    });
                }
            });
            [app run];
            return 0;
        }
        signal(SIGALRM, deadline); alarm(45);
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        if (provider) {
            NSDictionary *single = fetch([provider isEqual:@"claude"]);
            NSData *data = [NSJSONSerialization dataWithJSONObject:single options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
            fwrite(data.bytes, 1, data.length, stdout); puts(""); alarm(0); return 0;
        }
        NSDictionary *codex = fetch(NO), *claude = fetch(YES);
        NSDictionary *out = @{ @"captured_at": @((long long)NSDate.date.timeIntervalSince1970),
                                @"elapsed_ms": @((long long)((CFAbsoluteTimeGetCurrent() - start) * 1000)),
                                @"codex": codex, @"claude": claude };
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        fwrite(data.bytes, 1, data.length, stdout); puts("");
        alarm(0);
    }
    return 0;
}
