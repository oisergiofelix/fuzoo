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
        for (NSUInteger i = 0; i < zones.count; i++) {
            long t = ((long)now + [zones[i] secondsFromGMTForDate:date]) % 86400;
            if (t < 0) t += 86400;
            NSString *label = clocks[i][@"label"];
            if (i) [s appendString:@"  "];
            if (label.length) [s appendFormat:@"%@ ", label];
            [s appendFormat:@"%02ld:%02ld", t / 3600, t / 60 % 60];
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
    load();

    // Hora mora no canto direito: na primeira execução, o fuzoo nasce colado nos
    // ícones do sistema. Se a pessoa arrastar (⌘ + arrastar), o macOS lembra.
    NSString *posKey = @"NSStatusItem Preferred Position fuzoo";
    if (![defs objectForKey:posKey]) [defs setDouble:1 forKey:posKey];
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
    SMAppServiceStatus st = SMAppService.mainAppService.status;
    NSString *login = L(@"Iniciar com o sistema", @"Open at login");
    if (st == SMAppServiceStatusRequiresApproval)
        login = [login stringByAppendingString:L(@" (aprovar nos Ajustes…)", @" (approve in Settings…)")];
    [self add:m title:login action:@selector(toggleLogin:) obj:nil].state =
        st == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self add:m title:L(@"Sobre o fuzoo…", @"About fuzoo…") action:@selector(about:) obj:nil];
    [m addItemWithTitle:L(@"Sair", @"Quit") action:@selector(terminate:) keyEquivalent:@"q"];
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

- (void)about:(NSMenuItem *)it {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:SITE_URL]];
}

@end

int main(void) {
    @autoreleasepool {
        pt = [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"];
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        Fuzoo *delegate = [Fuzoo new];  // NSApp.delegate é weak; esta referência vive até o fim
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
