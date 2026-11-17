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
    if (!snapshot || [snapshot[@"reset"] compare:now] != NSOrderedDescending) return @"—";
    return [NSString stringWithFormat:@"%.0f", [snapshot[@"remaining"] doubleValue]];
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
@end

@implementation AIUsage
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _helperURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/UsageBridge.app"];
    _interval = 60;
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
    NSArray *providers = @[@[@"Codex", self.codex ?: @{}, @(self.codexEnabled)], @[@"Claude", self.claude ?: @{}, @(self.claudeEnabled)]];
    BOOL first = YES;
    for (NSArray *provider in providers) {
        if (![provider[2] boolValue]) continue;
        NSDictionary *snapshot = provider[1];
        NSString *balance = [self fresh:snapshot at:now] ? titleBalance(snapshot[@"session"], now) : @"—";
        if (!first) [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" · " attributes:normal]];
        first = NO;
        // Color is deliberately an exception signal, never a second text color.
        NSColor *accent = nil;
        if ([balance isEqual:@"—"]) accent = NSColor.secondaryLabelColor;
        else if (balance.integerValue < 10) accent = NSColor.systemRedColor;
        else if (balance.integerValue < 30) accent = NSColor.systemOrangeColor;
        if (accent) [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"● " attributes:@{ NSFontAttributeName: self.item.button.font, NSForegroundColorAttributeName: accent }]];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ %@", provider[0], balance] attributes:normal]];
    }
    if (!title.length) [title appendAttributedString:[[NSAttributedString alloc] initWithString:text(@"IA não configurada", @"AI not configured") attributes:normal]];
    self.item.button.attributedTitle = title;
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
    [menu addItemWithTitle:title action:nil keyEquivalent:@""].enabled = NO;
}
- (void)provider:(NSString *)name snapshot:(NSDictionary *)snapshot error:(NSString *)error menu:(NSMenu *)menu {
    [self row:menu title:name];
    NSDate *now = NSDate.date;
    if (!snapshot) { [self row:menu title:error ?: text(@"Aguardando consulta…", @"Waiting for usage…")]; return; }
    BOOL fresh = [self fresh:snapshot at:now];
    for (NSString *key in @[@"session", @"weekly"]) {
        NSDictionary *window = snapshot[key];
        NSString *label = [key isEqual:@"session"] ? text(@"5 horas", @"5 hours") : text(@"Semana", @"Week");
        NSString *value = fresh ? AIWindowRemaining(window, now) : @"—";
        [self row:menu title:[NSString stringWithFormat:text(@"%@: %@ restantes", @"%@: %@ remaining"), label, value]];
        NSDate *reset = window[@"reset"];
        if (reset) {
            NSInteger minutes = (NSInteger)ceil([reset timeIntervalSinceDate:now] / 60);
            NSString *remaining;
            if (minutes >= 1440) remaining = [NSString stringWithFormat:text(@"Reinicia em %ldd %ldh", @"Resets in %ldd %ldh"), (long)minutes / 1440, (long)minutes / 60 % 24];
            else if (minutes >= 60) remaining = [NSString stringWithFormat:text(@"Reinicia em %ldh %02ldmin", @"Resets in %ldh %02ldmin"), (long)minutes / 60, (long)minutes % 60];
            else if (minutes > 0) remaining = [NSString stringWithFormat:text(@"Reinicia em %ld min", @"Resets in %ld min"), (long)minutes];
            else remaining = text(@"Janela encerrada; aguardando nova consulta", @"Window ended; awaiting a new reading");
            [self row:menu title:remaining];
        }
    }
    NSInteger age = MAX(0, (NSInteger)[now timeIntervalSinceDate:snapshot[@"received"]] / 60);
    [self row:menu title:[NSString stringWithFormat:text(@"Atualizado há %ld min%@", @"Updated %ld min ago%@"), (long)age,
                         fresh ? @"" : text(@" · desatualizado", @" · stale")]];
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (self.codexEnabled) [self provider:@"Codex" snapshot:self.codex error:self.codexError menu:menu];
    if (self.codexEnabled && self.claudeEnabled) [menu addItem:NSMenuItem.separatorItem];
    if (self.claudeEnabled) [self provider:@"Claude" snapshot:self.claude error:self.claudeError menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh = [menu addItemWithTitle:self.task ? text(@"Atualizando…", @"Refreshing…") : text(@"Atualizar agora", @"Refresh now") action:@selector(refreshNow:) keyEquivalent:@""];
    refresh.target = self;
    refresh.enabled = !self.task && NSProcessInfo.processInfo.systemUptime >= self.retryNotBefore &&
        (!self.attempted || NSProcessInfo.processInfo.systemUptime - self.lastAttempt >= 60);
    NSMenuItem *connect = [menu addItemWithTitle:text(@"Conectar Claude…", @"Connect Claude…") action:@selector(connectClaude:) keyEquivalent:@""];
    connect.target = self;
    [self row:menu title:text(@"Consulta automática a cada 1 min; erros podem aumentar o intervalo.", @"Refreshes every 1 min; errors can increase the interval.")];
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
