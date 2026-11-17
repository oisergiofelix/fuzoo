// Manual integration diagnostic: uses the installed, consented helper.
#import "../src/AIUsage.h"
@interface AIUsage (LiveTest)
- (void)acceptResult:(id)result;
- (void)refreshNow:(id)sender;
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyAccessory;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"aiUsageCodexEnabled"];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"aiUsageClaudeEnabled"];
        AIUsage *usage = [AIUsage new];
        [usage setValue:[NSURL fileURLWithPath:@(argv[1])] forKey:@"helperURL"];
        [usage refreshIfNeeded];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:50];
        while ([usage valueForKey:@"task"] && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        NSStatusItem *item = [usage valueForKey:@"item"];
        BOOL ready = [usage valueForKey:@"codex"] && [usage valueForKey:@"claude"];
        printf("title: %s\nboth providers ready: %s\n", item.button.title.UTF8String, ready ? "yes" : "no");
        if (!ready) {
            printf("codex: %s\nclaude: %s\n", [[usage valueForKey:@"codexError"] UTF8String] ?: "ok",
                   [[usage valueForKey:@"claudeError"] UTF8String] ?: "ok");
        }
        if (ready) {
            [usage refreshIfNeeded];
            NSCAssert(![usage valueForKey:@"task"], @"Minute ticks cannot query again within the interval");
            [usage menuNeedsUpdate:item.menu];
            for (NSMenuItem *row in item.menu.itemArray) if (!row.isSeparatorItem) printf("menu: %s\n", row.title.UTF8String);
            [usage menuDidClose:item.menu];
            NSCAssert(item.menu.numberOfItems == 0, @"Menu content released when closed");
            for (NSString *key in @[@"codex", @"claude"]) {
                NSMutableDictionary *snapshot = [[usage valueForKey:key] mutableCopy];
                snapshot[@"received"] = [NSDate dateWithTimeIntervalSinceNow:-601];
                [usage setValue:snapshot forKey:key];
            }
            [usage refreshIfNeeded];
            NSCAssert([item.button.title containsString:@"?"], @"Stale balances hidden, never shown as zero");
            [usage acceptResult:@{@"codex": @{@"state": @"http_error", @"http_status": @429, @"retry_after_seconds": @3600}}];
            [usage refreshNow:nil];
            NSCAssert(![usage valueForKey:@"task"], @"Manual refresh respects the service retry window");
            [usage setValue:@0 forKey:@"retryNotBefore"];
            [usage setValue:@NO forKey:@"attempted"];
            [usage refreshIfNeeded];
        }
        [usage stop];
        NSCAssert(![usage valueForKey:@"task"] && ![usage valueForKey:@"item"] && ![usage valueForKey:@"terminationObserver"],
                  @"Disabling releases process, status item and observer");
        return ready ? 0 : 1;
    }
}
