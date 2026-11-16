// fuzoo — relógios de outros fusos horários na barra de menus do macOS.
// fuzoo — tiny world clocks for the macOS menu bar.
//
// Princípios / principles:
//   - um arquivo, sem dependências além do AppKit;
//   - acorda uma vez por minuto, na virada exata, via timer de relógio de parede;
//   - hora calculada com aritmética (offset do fuso), sem DateFormatter;
//   - o menu só é montado quando alguém clica.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#include <time.h>

#define SITE_URL @"https://oisergiofelix.github.io/fuzoo/"
#define ROADMAP_URL @"https://oisergiofelix.github.io/fuzoo/roadmap.html"

static BOOL pt;  // interface em português se o sistema estiver em português
#define L(ptString, enString) (pt ? (ptString) : (enString))

// {rótulo, nome PT, nome EN, identificador IANA}. Rótulo nil = título de seção.
static NSString *const kPresets[][4] = {
    {nil, @"Brasil", @"Brazil", nil},
    {@"SP", @"São Paulo / Brasília", @"São Paulo / Brasília", @"America/Sao_Paulo"},
    {@"CG", @"Campo Grande", @"Campo Grande", @"America/Campo_Grande"},
    {@"CB", @"Cuiabá", @"Cuiabá", @"America/Cuiaba"},
    {@"MAN", @"Manaus", @"Manaus", @"America/Manaus"},
    {@"RB", @"Rio Branco", @"Rio Branco", @"America/Rio_Branco"},
    {@"FN", @"Fernando de Noronha", @"Fernando de Noronha", @"America/Noronha"},
    {nil, @"Mundo", @"World", nil},
    {@"UTC", @"UTC", @"UTC", @"UTC"},
    {@"BA", @"Buenos Aires", @"Buenos Aires", @"America/Argentina/Buenos_Aires"},
    {@"NY", @"Nova York", @"New York", @"America/New_York"},
    {@"LA", @"Los Angeles", @"Los Angeles", @"America/Los_Angeles"},
    {@"LIS", @"Lisboa", @"Lisbon", @"Europe/Lisbon"},
    {@"LON", @"Londres", @"London", @"Europe/London"},
    {@"BER", @"Berlim", @"Berlin", @"Europe/Berlin"},
    {@"TYO", @"Tóquio", @"Tokyo", @"Asia/Tokyo"},
};
#define NPRESETS (sizeof kPresets / sizeof kPresets[0])

static NSUserDefaults *defs;
static NSStatusItem *item;
static dispatch_source_t timer;
static NSArray<NSDictionary *> *clocks;  // só entradas válidas: {label, tz}
static NSArray<NSTimeZone *> *zones;     // alinhado com clocks
static NSCalendar *dateCalendar;
static NSInteger dateMode;                // 0 = desligada, 1 = curta

static NSString *const kWeekdaysPT[] = {@"Domingo", @"Segunda", @"Terça", @"Quarta", @"Quinta", @"Sexta", @"Sábado"};
static NSString *const kMonthsPT[] = {@"janeiro", @"fevereiro", @"março", @"abril", @"maio", @"junho", @"julho", @"agosto", @"setembro", @"outubro", @"novembro", @"dezembro"};
static NSString *const kMonthsShortPT[] = {@"jan", @"fev", @"mar", @"abr", @"mai", @"jun", @"jul", @"ago", @"set", @"out", @"nov", @"dez"};
static NSString *const kWeekdaysEN[] = {@"Sunday", @"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday"};
static NSString *const kMonthsEN[] = {@"January", @"February", @"March", @"April", @"May", @"June", @"July", @"August", @"September", @"October", @"November", @"December"};
static NSString *const kMonthsShortEN[] = {@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"};

static void refreshPresentation(void) {
    pt = [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"];
    dateCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    dateCalendar.timeZone = NSTimeZone.localTimeZone;
}

static NSString *dateText(NSDate *date, BOOL full) {
    NSDateComponents *c = [dateCalendar components:NSCalendarUnitWeekday | NSCalendarUnitDay | NSCalendarUnitMonth
                                          fromDate:date];
    NSUInteger weekday = MAX(1, c.weekday) - 1, month = MAX(1, c.month) - 1;
    if (pt) {
        NSString *m = full ? kMonthsPT[month] : kMonthsShortPT[month];
        return full ? [NSString stringWithFormat:@"%@, %ld de %@", kWeekdaysPT[weekday], (long)c.day, m]
                    : [NSString stringWithFormat:@"%@, %ld %@", kWeekdaysPT[weekday], (long)c.day, m];
    }
    NSString *m = full ? kMonthsEN[month] : kMonthsShortEN[month];
    return [NSString stringWithFormat:@"%@, %@ %ld", kWeekdaysEN[weekday], m, (long)c.day];
}

static long dayNumber(time_t now, NSTimeZone *zone, NSDate *date) {
    return ((long)now + [zone secondsFromGMTForDate:date]) / 86400;
}

static void load(void) {
    NSMutableArray *c = [NSMutableArray new], *z = [NSMutableArray new];
    for (id d in [defs arrayForKey:@"clocks"]) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        id l = d[@"label"], t = d[@"tz"];
        NSTimeZone *tz = [t isKindOfClass:NSString.class] ? [NSTimeZone timeZoneWithName:t] : nil;
        if (!tz) continue;
        [c addObject:@{@"label" : [l isKindOfClass:NSString.class] ? l : @"", @"tz" : t}];
        [z addObject:tz];
    }
    clocks = c;
    zones = z;
}

static void tick(void *ctx) {
    (void)ctx;
    @autoreleasepool {
        time_t now = time(NULL);
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:now];
        NSMutableString *s = [NSMutableString new];
        long localDay = dayNumber(now, NSTimeZone.localTimeZone, date);
        if (dateMode) [s appendString:dateText(date, NO)];
        for (NSUInteger i = 0; i < zones.count; i++) {
            long t = ((long)now + [zones[i] secondsFromGMTForDate:date]) % 86400;
            if (t < 0) t += 86400;
            NSString *label = clocks[i][@"label"];
            if (s.length) [s appendString:dateMode ? @" · " : @"  "];
            if (label.length) [s appendFormat:@"%@ ", label];
            [s appendFormat:@"%02ld:%02ld", t / 3600, t / 60 % 60];
            if (dateMode) {
                long delta = dayNumber(now, zones[i], date) - localDay;
                if (delta) [s appendFormat:@" %+ldd", delta];
            }
        }
        item.button.title = s.length ? s : @"fuzoo";

        // Próximo disparo: exatamente na virada do minuto (relógio de parede,
        // então sobrevive a sono/despertar). 1 s de folga para o sistema agrupar.
        struct timespec next = {.tv_sec = now - now % 60 + 60};
        dispatch_source_set_timer(timer, dispatch_walltime(&next, 0), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    }
}

static void save(NSArray *c) {
    [defs setObject:c forKey:@"clocks"];
    load();
    tick(NULL);
}

static NSString *offsetString(NSTimeZone *tz) {
    long o = [tz secondsFromGMTForDate:[NSDate date]];
    long a = labs(o);
    NSString *sign = o < 0 ? @"−" : @"+";
    if (a % 3600) return [NSString stringWithFormat:@"UTC%@%ld:%02ld", sign, a / 3600, a / 60 % 60];
    return o ? [NSString stringWithFormat:@"UTC%@%ld", sign, a / 3600] : @"UTC";
}

static NSString *cityName(NSString *tz) {
    return [tz.lastPathComponent stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

static void alert(NSString *title, NSString *text) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text;
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
}

// Pede rótulo (e fuso, se askTz). Retorna @[rótulo, fuso] ou nil se cancelado.
static NSArray<NSString *> *ask(NSString *title, NSString *label, NSString *tz, BOOL askTz) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    if (askTz)
        a.informativeText = L(@"Use um identificador IANA, como America/Sao_Paulo ou Europe/Lisbon.",
                              @"Use an IANA identifier, like America/New_York or Europe/Lisbon.");
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:L(@"Cancelar", @"Cancel")];

    NSTextField *fl = [NSTextField textFieldWithString:label ?: @""];
    NSTextField *fz = [NSTextField textFieldWithString:tz ?: @""];
    fl.placeholderString = L(@"Rótulo (ex.: CG)", @"Label (e.g. NY)");
    fz.placeholderString = L(@"Fuso (ex.: America/Campo_Grande)", @"Time zone (e.g. America/New_York)");
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, askTz ? 54 : 24)];
    fl.frame = NSMakeRect(0, askTz ? 30 : 0, 260, 24);
    fz.frame = NSMakeRect(0, 0, 260, 24);
    [v addSubview:fl];
    if (askTz) [v addSubview:fz];
    a.accessoryView = v;
    a.window.initialFirstResponder = fl;

    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] != NSAlertFirstButtonReturn) return nil;
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    return @[ [fl.stringValue stringByTrimmingCharactersInSet:ws], [fz.stringValue stringByTrimmingCharactersInSet:ws] ];
}

@interface Fuzoo : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation Fuzoo

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    defs = NSUserDefaults.standardUserDefaults;
    [defs registerDefaults:@{
        @"clocks" : @[
            @{@"label" : @"CG", @"tz" : @"America/Campo_Grande"},
            @{@"label" : @"SP", @"tz" : @"America/Sao_Paulo"},
        ]
    }];
    dateMode = [defs integerForKey:@"dateMode"];
    refreshPresentation();
    load();

    // O macOS controla a ordem dos itens da barra. autosaveName faz com que ele
    // preserve a posição que a pessoa escolher com ⌘ + arrastar.
    item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    item.autosaveName = @"fuzoo";
    CGFloat size = item.button.font.pointSize;
    item.button.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
    NSMenu *m = [NSMenu new];
    m.delegate = self;
    m.autoenablesItems = NO;
    item.menu = m;

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler_f(timer, tick);
    dispatch_activate(timer);
    tick(NULL);

    // Usuário ou NTP ajustou o relógio do sistema: redesenha e realinha o timer.
    [NSNotificationCenter.defaultCenter addObserverForName:NSSystemClockDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *x) { tick(NULL); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSSystemTimeZoneDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *x) { refreshPresentation(); tick(NULL); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSCurrentLocaleDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *x) { refreshPresentation(); tick(NULL); }];
}

#pragma mark Menu (montado sob demanda)

- (NSMenuItem *)add:(NSMenu *)m title:(NSString *)title action:(SEL)action obj:(id)obj {
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:@""];
    it.target = self;
    it.representedObject = obj;
    return it;
}

- (void)addPresets:(NSMenu *)m forClock:(NSUInteger)i current:(NSString *)tz {
    for (NSUInteger p = 0; p < NPRESETS; p++) {
        NSString *name = kPresets[p][pt ? 1 : 2];
        if (!kPresets[p][0]) {
            if (p) [m addItem:NSMenuItem.separatorItem];
            [m addItemWithTitle:name action:nil keyEquivalent:@""].enabled = NO;
            continue;
        }
        NSString *t = [NSString stringWithFormat:@"%@  (%@)", name, kPresets[p][0]];
        NSMenuItem *it = [self add:m title:t action:@selector(pickPreset:) obj:@[ @(i), @(p) ]];
        it.state = [tz isEqualToString:kPresets[p][3]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [m addItem:NSMenuItem.separatorItem];
    [self add:m title:L(@"Outro fuso…", @"Other time zone…") action:@selector(other:) obj:@(i)];
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    [m removeAllItems];

    NSMenuItem *today = [m addItemWithTitle:dateText(NSDate.date, YES) action:nil keyEquivalent:@""];
    today.enabled = NO;
    [m addItem:NSMenuItem.separatorItem];

    for (NSUInteger i = 0; i < clocks.count; i++) {
        NSString *label = clocks[i][@"label"], *tz = clocks[i][@"tz"];
        NSString *t = [NSString stringWithFormat:@"%@%@%@  (%@)", label, label.length ? @" — " : @"",
                                                 cityName(tz), offsetString(zones[i])];
        NSMenu *sub = [NSMenu new];
        sub.autoenablesItems = NO;
        [self addPresets:sub forClock:i current:tz];
        [self add:sub title:L(@"Renomear rótulo…", @"Rename label…") action:@selector(rename:) obj:@(i)];
        [sub addItem:NSMenuItem.separatorItem];
        [self add:sub title:L(@"Remover", @"Remove") action:@selector(remove:) obj:@(i)].enabled = clocks.count > 1;
        [m addItemWithTitle:t action:nil keyEquivalent:@""].submenu = sub;
    }

    [m addItem:NSMenuItem.separatorItem];
    NSMenu *addSub = [NSMenu new];
    addSub.autoenablesItems = NO;
    [self addPresets:addSub forClock:clocks.count current:nil];
    [m addItemWithTitle:L(@"Adicionar relógio", @"Add clock") action:nil keyEquivalent:@""].submenu = addSub;

    [m addItem:NSMenuItem.separatorItem];
    NSMenu *dateSub = [NSMenu new];
    dateSub.autoenablesItems = NO;
    NSMenuItem *off = [self add:dateSub title:L(@"Desligada", @"Off") action:@selector(setDateMode:) obj:@0];
    off.state = dateMode == 0 ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *shortDate = [self add:dateSub title:L(@"Curta", @"Short") action:@selector(setDateMode:) obj:@1];
    shortDate.state = dateMode == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItemWithTitle:L(@"Mostrar data", @"Show date") action:nil keyEquivalent:@""].submenu = dateSub;

    SMAppServiceStatus st = SMAppService.mainAppService.status;
    NSString *login = L(@"Iniciar com o sistema", @"Open at login");
    if (st == SMAppServiceStatusRequiresApproval)
        login = [login stringByAppendingString:L(@" (aprovar nos Ajustes…)", @" (approve in Settings…)")];
    [self add:m title:login action:@selector(toggleLogin:) obj:nil].state =
        st == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self add:m title:L(@"Sobre o fuzoo…", @"About fuzoo…") action:@selector(about:) obj:nil];
    [self add:m title:L(@"Roadmap público", @"Public roadmap") action:@selector(roadmap:) obj:nil];
    [m addItemWithTitle:L(@"Sair", @"Quit") action:@selector(terminate:) keyEquivalent:@"q"];
}

- (void)menuDidClose:(NSMenu *)m {
    // Os itens e submenus existem apenas enquanto o menu está aberto.
    [m removeAllItems];
}

#pragma mark Ações

- (void)setClock:(NSUInteger)i label:(NSString *)label tz:(NSString *)tz {
    NSMutableArray *c = [clocks mutableCopy];
    NSDictionary *d = @{@"label" : label, @"tz" : tz};
    if (i < c.count) c[i] = d;
    else [c addObject:d];
    save(c);
}

- (void)pickPreset:(NSMenuItem *)it {
    NSUInteger i = [it.representedObject[0] unsignedIntegerValue], p = [it.representedObject[1] unsignedIntegerValue];
    [self setClock:i label:kPresets[p][0] tz:kPresets[p][3]];
}

- (void)other:(NSMenuItem *)it {
    NSUInteger i = [it.representedObject unsignedIntegerValue];
    BOOL exists = i < clocks.count;
    NSArray *r = ask(exists ? L(@"Trocar fuso", @"Change time zone") : L(@"Adicionar relógio", @"Add clock"),
                     exists ? clocks[i][@"label"] : nil, exists ? clocks[i][@"tz"] : nil, YES);
    if (!r) return;
    if (![NSTimeZone timeZoneWithName:r[1]]) {
        alert(L(@"Fuso não encontrado", @"Time zone not found"),
              [NSString stringWithFormat:L(@"“%@” não é um identificador IANA válido.",
                                           @"“%@” is not a valid IANA identifier."), r[1]]);
        return;
    }
    [self setClock:i label:r[0] tz:r[1]];
}

- (void)rename:(NSMenuItem *)it {
    NSUInteger i = [it.representedObject unsignedIntegerValue];
    NSArray *r = ask(L(@"Renomear rótulo", @"Rename label"), clocks[i][@"label"], nil, NO);
    if (r) [self setClock:i label:r[0] tz:clocks[i][@"tz"]];
}

- (void)remove:(NSMenuItem *)it {
    NSMutableArray *c = [clocks mutableCopy];
    [c removeObjectAtIndex:[it.representedObject unsignedIntegerValue]];
    save(c);
}

- (void)toggleLogin:(NSMenuItem *)it {
    SMAppService *s = SMAppService.mainAppService;
    if (s.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }
    NSError *e = nil;
    BOOL ok = s.status == SMAppServiceStatusEnabled ? [s unregisterAndReturnError:&e] : [s registerAndReturnError:&e];
    if (!ok) alert(L(@"Não foi possível alterar o início automático", @"Couldn't change open at login"),
                   e.localizedDescription);
}

- (void)setDateMode:(NSMenuItem *)it {
    dateMode = [it.representedObject integerValue];
    [defs setInteger:dateMode forKey:@"dateMode"];
    tick(NULL);
}

- (void)about:(NSMenuItem *)it {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:SITE_URL]];
}

- (void)roadmap:(NSMenuItem *)it {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:ROADMAP_URL]];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        Fuzoo *delegate = [Fuzoo new];  // NSApp.delegate é weak; esta referência vive até o fim
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
