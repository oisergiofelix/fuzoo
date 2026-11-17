#import "AIUsage.h"
#include <math.h>

static NSString *text(NSString *pt, NSString *en) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"] ? pt : en;
}
static BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([value doubleValue]);
}
static NSDictionary *readWindow(id raw) {
    if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"state"] isEqual:@"ok"]) return nil;
    id percent = raw[@"remaining_percent"], reset = raw[@"reset_at"];
    if (!number(percent) || [percent doubleValue] < 0 || [percent doubleValue] > 100) return nil;
    NSDate *date;
    if (number(reset) && [reset doubleValue] > 0) date = [NSDate dateWithTimeIntervalSince1970:[reset doubleValue]];
    else if ([reset isKindOfClass:NSString.class]) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        date = [formatter dateFromString:reset];
        if (!date) { formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; date = [formatter dateFromString:reset]; }
    }
    // A percentage with no reliable expiry must not live indefinitely.
    return date ? @{@"remaining": percent, @"reset": date} : nil;
}
NSDictionary *AIProviderSnapshot(id raw, NSDate *received) {
    if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"state"] isEqual:@"ok"]) return nil;
    NSDictionary *session = readWindow(raw[@"session"]), *weekly = readWindow(raw[@"weekly"]);
    // A successful HTTP response is not enough: this feature promises the current
    // session. Never call a provider connected without that usable window.
    if (!session) return nil;
    NSMutableDictionary *out = [@{@"received": received} mutableCopy];
    if (session) out[@"session"] = session;
    if (weekly) out[@"weekly"] = weekly;
    return out;
}
NSString *AIWindowRemaining(id window, NSDate *now) {
    if (![window isKindOfClass:NSDictionary.class] || [window[@"reset"] compare:now] != NSOrderedDescending) return @"—";
    return [NSString stringWithFormat:@"%.0f%%", [window[@"remaining"] doubleValue]];
}

static NSString *titleBalance(NSDictionary *snapshot, NSDate *now) {
    if (!snapshot || [snapshot[@"reset"] compare:now] != NSOrderedDescending) return @"?";
    return [NSString stringWithFormat:@"%.0f", [snapshot[@"remaining"] doubleValue]];
}

static NSImage *localMenuBarIcon(NSString *templatePath, CGFloat size, NSArray<NSString *> *bundleIDs, NSArray<NSString *> *paths) {
    NSString *retinaPath = [[templatePath stringByDeletingPathExtension] stringByAppendingString:@"@2x.png"];
    NSImage *template = [[NSImage alloc] initWithContentsOfFile:retinaPath];
    if (!template) template = [[NSImage alloc] initWithContentsOfFile:templatePath];
    if (template) { template.template = YES; template.size = NSMakeSize(size, size); return template; }
    for (NSString *identifier in bundleIDs) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier].firstObject;
        if (app.bundleURL) { NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:app.bundleURL.path]; icon.size = NSMakeSize(size, size); return icon; }
    }
    for (NSString *path in paths) if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:path]; icon.size = NSMakeSize(size, size); return icon;
    }
    return nil;
}

@interface AIIconCell : NSTextAttachmentCell
@end
@implementation AIIconCell
- (NSPoint)cellBaselineOffset {
    // Keep the visual centre fixed as the icon's optical size changes.
    return NSMakePoint(0, -4 - (self.image.size.height - 18) / 2);
}
@end

static NSAttributedString *iconText(NSImage *image, NSString *fallback, NSDictionary *attributes) {
    if (!image) return [[NSAttributedString alloc] initWithString:fallback attributes:attributes];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.attachmentCell = [[AIIconCell alloc] initImageCell:image];
    return [NSAttributedString attributedStringWithAttachment:attachment];
}

@interface AIUsage ()
@property NSStatusItem *item;
@property NSTask *task;
@property NSURL *helperURL;
@property NSDictionary *codex, *claude;
@property NSString *codexError, *claudeError;
@property NSTimeInterval lastAttempt, interval;
@property NSTimeInterval retryNotBefore;
@property NSUInteger failures;
@property BOOL stopped, attempted;
@property id terminationObserver;
@property id wakeObserver;
@property BOOL codexEnabled, claudeEnabled;
@property NSImage *codexIcon, *claudeIcon;
@end

@implementation AIUsage
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _helperURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/UsageBridge.app"];
    _interval = 60;
    _codexIcon = localMenuBarIcon(@"/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png", 18, @[], @[]);
    _claudeIcon = localMenuBarIcon(@"/Applications/Claude.app/Contents/Resources/TrayIconTemplate.png", 22, @[], @[]);
    _codexEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"aiUsageCodexEnabled"];
    _claudeEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"aiUsageClaudeEnabled"];
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.autosaveName = @"fuzoo.ai";
    _item.button.font = [NSFont monospacedDigitSystemFontOfSize:_item.button.font.pointSize weight:NSFontWeightRegular];
    NSMenu *menu = [NSMenu new]; menu.autoenablesItems = NO; menu.delegate = self; _item.menu = menu;
    __weak AIUsage *weakSelf = self;
    _terminationObserver = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if ([app.bundleIdentifier isEqual:@"io.github.oisergiofelix.fuzoo.usage-bridge"]) {
                AIUsage *owner = weakSelf;
                if (owner && !owner.stopped) { owner.attempted = NO; [owner refreshIfNeeded]; }
            }
        }];
    _wakeObserver = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [weakSelf refreshIfNeeded];
        }];
    [self updateTitle];
    return self;
}
- (BOOL)fresh:(NSDictionary *)snapshot at:(NSDate *)now {
    NSTimeInterval age = [now timeIntervalSinceDate:snapshot[@"received"] ?: NSDate.distantPast];
    return snapshot && age >= 0 && age < 180;
}
- (void)updateTitle {
    NSDate *now = NSDate.date;
    NSMutableAttributedString *title = [NSMutableAttributedString new];
    NSDictionary *normal = @{ NSFontAttributeName: self.item.button.font, NSForegroundColorAttributeName: NSColor.labelColor };
    NSImage *codexIcon = self.codexIcon;
    NSImage *claudeIcon = self.claudeIcon;
    NSArray *providers = @[@[@"Codex", self.codex ?: @{}, @(self.codexEnabled), codexIcon ?: NSNull.null], @[@"Claude", self.claude ?: @{}, @(self.claudeEnabled), claudeIcon ?: NSNull.null]];
    BOOL first = YES;
    for (NSArray *provider in providers) {
        if (![provider[2] boolValue]) continue;
        NSDictionary *snapshot = provider[1];
        NSString *balance = [self fresh:snapshot at:now] ? titleBalance(snapshot[@"session"], now) : @"?";
        if (!first) [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" : " attributes:normal]];
        first = NO;
        // Color is deliberately an exception signal, never a second text color.
        NSColor *accent = nil;
        if ([balance isEqual:@"?"]) accent = NSColor.secondaryLabelColor;
        else if (balance.integerValue < 10) accent = NSColor.systemRedColor;
        else if (balance.integerValue < 30) accent = NSColor.systemOrangeColor;
        if (accent) [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"● " attributes:@{ NSFontAttributeName: self.item.button.font, NSForegroundColorAttributeName: accent }]];
        NSImage *icon = provider[3] == NSNull.null ? nil : provider[3];
        [title appendAttributedString:iconText(icon, provider[0], normal)];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" %@", balance] attributes:normal]];
    }
    if (!title.length) [title appendAttributedString:[[NSAttributedString alloc] initWithString:text(@"IA não configurada", @"AI not configured") attributes:normal]];
    self.item.button.attributedTitle = title;
    self.item.button.accessibilityLabel = [NSString stringWithFormat:@"Codex %@, Claude %@", [self fresh:self.codex at:now] ? titleBalance(self.codex[@"session"], now) : @"unavailable", [self fresh:self.claude at:now] ? titleBalance(self.claude[@"session"], now) : @"unavailable"];
    self.item.button.toolTip = text(@"Percentual restante da sessão atual. Consulta local, no máximo uma vez por minuto.",
                                   @"Remaining in the current session. Local query, at most once a minute.");
}
- (void)refreshIfNeeded {
    if (self.stopped) return;
    [self updateTitle];
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    if (!self.codexEnabled && !self.claudeEnabled) return;
    if (self.task || uptime < self.retryNotBefore || (self.attempted && uptime - self.lastAttempt < self.interval)) return;
    self.attempted = YES; self.lastAttempt = uptime;
    NSTask *task = [NSTask new]; NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [self.helperURL URLByAppendingPathComponent:@"Contents/MacOS/usage-bridge"];
    task.arguments = @[@"--background"];
    task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    self.task = task;
    __weak AIUsage *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        id result = data.length <= 16384 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            AIUsage *owner = weakSelf;
            if (!owner || owner.stopped || owner.task != finished) return;
            owner.task = nil;
            [owner acceptResult:finished.terminationStatus == 0 ? result : nil];
        });
    };
    NSError *error;
    if (![task launchAndReturnError:&error]) { self.task = nil; [self acceptResult:nil]; }
}
- (NSString *)errorText:(id)raw {
    if (![raw isKindOfClass:NSDictionary.class]) return text(@"Consulta indisponível", @"Usage unavailable");
    if ([raw[@"state"] isEqual:@"credentials_unavailable"])
        return text(@"Conecte a sessão ou autorize o acesso", @"Sign in or authorize access");
    if ([raw[@"http_status"] isEqual:@401] || [raw[@"http_status"] isEqual:@403])
        return text(@"Sessão expirada ou acesso negado", @"Session expired or access denied");
    if ([raw[@"http_status"] isEqual:@429]) return text(@"Serviço pediu uma pausa", @"Service requested a pause");
    return text(@"Consulta indisponível", @"Usage unavailable");
}
- (void)acceptResult:(id)raw {
    NSDictionary *result = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    NSDate *now = NSDate.date;
    // Replace on error too: never carry an old account's balance into a failed login.
    self.codex = AIProviderSnapshot(result[@"codex"], now);
    self.claude = AIProviderSnapshot(result[@"claude"], now);
    self.codexError = self.codex ? nil : [self errorText:result[@"codex"]];
    self.claudeError = self.claude ? nil : [self errorText:result[@"claude"]];
    self.failures = (!self.codex && !self.claude) ? MIN(self.failures + 1, 4) : 0;
    self.interval = 60 * (1 << self.failures);
    self.retryNotBefore = 0;
    for (NSString *key in @[@"codex", @"claude"]) {
        id provider = result[key];
        if (![provider isKindOfClass:NSDictionary.class]) continue;
        if ([provider[@"http_status"] isEqual:@429]) self.interval = MAX(self.interval, 900);
        id retry = provider[@"retry_after_seconds"];
        if (number(retry) && [retry doubleValue] > 0) self.interval = MAX(self.interval, MIN([retry doubleValue], 86400));
        if ([provider[@"http_status"] isEqual:@429] || (number(retry) && [retry doubleValue] > 0))
            self.retryNotBefore = NSProcessInfo.processInfo.systemUptime + self.interval;
    }
    [self updateTitle];
}
- (void)row:(NSMenu *)menu title:(NSString *)title {
    // Informational rows are labels, not disabled commands. Native disabled
    // menu text is too faint over a translucent menu background.
    NSMenuItem *row = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 350, 25)];
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:13];
    label.textColor = NSColor.labelColor;
    label.frame = NSMakeRect(16, 4, 320, 18);
    BOOL heading = [title isEqual:@"Codex"] || [title isEqual:@"Claude"];
    BOOL metadata = [title hasPrefix:@"Atualizado"] || [title hasPrefix:@"Updated"] || [title hasPrefix:@"Limites de IA"] || [title hasPrefix:@"AI limits"];
    if (heading) label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    if (metadata) { label.font = [NSFont systemFontOfSize:11]; label.textColor = NSColor.secondaryLabelColor; }
    NSRange reset = [title rangeOfString:@" - "];
    if (reset.location != NSNotFound && !metadata) {
        label.stringValue = [title substringToIndex:reset.location];
        label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
        NSTextField *detail = [NSTextField labelWithString:[title substringFromIndex:NSMaxRange(reset)]];
        detail.font = [NSFont systemFontOfSize:11]; detail.textColor = NSColor.secondaryLabelColor;
        detail.frame = NSMakeRect(16, 2, 320, 16);
        label.frame = NSMakeRect(16, 19, 320, 18);
        view.frame = NSMakeRect(0, 0, 350, 40);
        [view addSubview:detail];
    }
    [view addSubview:label]; row.view = view;
}
- (void)appendInfoBlock:(NSMenu *)source to:(NSMenu *)destination {
    CGFloat height = 12;
    for (NSMenuItem *row in source.itemArray) height += row.view.frame.size.height;
    NSView *block = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 350, height)];
    CGFloat top = height - 6;
    for (NSMenuItem *row in source.itemArray) {
        NSView *view = row.view;
        // Detach ownership before reparenting. Otherwise source-menu teardown
        // removes its item views from the destination block as well.
        row.view = nil;
        top -= view.frame.size.height;
        view.frame = NSMakeRect(0, top, 350, view.frame.size.height);
        [block addSubview:view];
    }
    NSMenuItem *item = [NSMenuItem new]; item.view = block;
    [destination addItem:item];
    [source removeAllItems];
    NSAssert(block.subviews.count > 0, @"Provider information must survive temporary menu teardown");
}
- (void)provider:(NSString *)name snapshot:(NSDictionary *)snapshot error:(NSString *)error menu:(NSMenu *)menu {
    NSMenu *destination = menu;
    menu = [NSMenu new];
    [self row:menu title:name];
    NSDate *now = NSDate.date;
    if (!snapshot) { [self row:menu title:error ?: text(@"Aguardando consulta…", @"Waiting for usage…")]; [self appendInfoBlock:menu to:destination]; return; }
    BOOL fresh = [self fresh:snapshot at:now];
    for (NSString *key in @[@"session", @"weekly"]) {
        NSDictionary *window = snapshot[key];
        if (!window) continue;
        NSString *label = [key isEqual:@"session"] ? text(@"Sessão", @"Session") : text(@"Semana", @"Week");
        NSString *value = fresh ? AIWindowRemaining(window, now) : @"—";
        NSDate *reset = window[@"reset"];
        if (reset) {
            NSInteger minutes = (NSInteger)ceil([reset timeIntervalSinceDate:now] / 60);
            NSString *remaining;
            if (minutes >= 1440) remaining = [NSString stringWithFormat:text(@"Reinicia em %ldd %ldh", @"Resets in %ldd %ldh"), (long)minutes / 1440, (long)minutes / 60 % 24];
            else if (minutes >= 60) remaining = [NSString stringWithFormat:text(@"Reinicia em %ldh %02ldmin", @"Resets in %ldh %02ldmin"), (long)minutes / 60, (long)minutes % 60];
            else if (minutes > 0) remaining = [NSString stringWithFormat:text(@"Reinicia em %ld min", @"Resets in %ld min"), (long)minutes];
            else remaining = text(@"Janela encerrada; aguardando nova consulta", @"Window ended; awaiting a new reading");
            [self row:menu title:[NSString stringWithFormat:@"%@: %@ - %@", label, value, remaining]];
        }
    }
    NSInteger age = MAX(0, (NSInteger)[now timeIntervalSinceDate:snapshot[@"received"]] / 60);
    [self row:menu title:age == 0 ? text(@"Atualizado agora", @"Updated just now") : [NSString stringWithFormat:text(@"Atualizado há %ld min%@", @"Updated %ld min ago%@"), (long)age,
                         fresh ? @"" : text(@" - desatualizado", @" - stale")]];
    [self appendInfoBlock:menu to:destination];
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [self row:menu title:text(@"Limites de IA - saldo restante", @"AI limits - remaining allowance")];
    [menu addItem:NSMenuItem.separatorItem];
    if (self.codexEnabled) [self provider:@"Codex" snapshot:self.codex error:self.codexError menu:menu];
    if (self.codexEnabled && self.claudeEnabled) [menu addItem:NSMenuItem.separatorItem];
    if (self.claudeEnabled) [self provider:@"Claude" snapshot:self.claude error:self.claudeError menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh = [menu addItemWithTitle:self.task ? text(@"Atualizando…", @"Refreshing…") : text(@"Atualizar agora", @"Refresh now") action:@selector(refreshNow:) keyEquivalent:@""];
    refresh.target = self;
    refresh.enabled = !self.task && NSProcessInfo.processInfo.systemUptime >= self.retryNotBefore &&
        (!self.attempted || NSProcessInfo.processInfo.systemUptime - self.lastAttempt >= 60);
    if (self.claudeEnabled && !self.claude) {
        NSMenuItem *connect = [menu addItemWithTitle:text(@"Reconectar Claude…", @"Reconnect Claude…") action:@selector(connectClaude:) keyEquivalent:@""];
        connect.target = self;
    }
}
- (void)menuDidClose:(NSMenu *)menu { [menu removeAllItems]; }
- (void)refreshNow:(id)sender { self.interval = 0; [self refreshIfNeeded]; }
- (void)connectClaude:(id)sender {
    NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
    config.activates = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:self.helperURL configuration:config completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ self.claudeError = text(@"Não foi possível abrir o conector", @"Could not open the connector"); });
    }];
}
- (void)stop {
    self.stopped = YES;
    if (self.task.running) [self.task terminate];
    self.task = nil;
    if (self.terminationObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.terminationObserver];
    self.terminationObserver = nil;
    if (self.wakeObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.wakeObserver];
    self.wakeObserver = nil;
    self.item.menu.delegate = nil;
    if (self.item) [NSStatusBar.systemStatusBar removeStatusItem:self.item];
    self.item = nil;
}
- (void)dealloc { [self stop]; }
@end
