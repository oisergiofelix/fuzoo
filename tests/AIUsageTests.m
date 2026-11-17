#import "../src/AIUsage.h"

static NSDictionary *provider(id session, id weekly) {
    return @{@"state": @"ok", @"session": session ?: NSNull.null, @"weekly": weekly ?: NSNull.null};
}
int main(void) {
    @autoreleasepool {
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:1794866400];
        NSDictionary *valid = @{@"state": @"ok", @"remaining_percent": @81,
                                @"reset_at": @"2026-11-16T23:00:00.543616+00:00"};
        NSDictionary *snapshot = AIProviderSnapshot(provider(valid, nil), now);
        NSCAssert([AIWindowRemaining(snapshot[@"session"], now) isEqual:@"81%"], @"Claude ISO reset parses");
        NSCAssert([AIWindowRemaining(snapshot[@"weekly"], now) isEqual:@"—"], @"Missing weekly stays unknown");
        NSCAssert([AIWindowRemaining(snapshot[@"session"], [NSDate dateWithTimeIntervalSince1970:1794870001]) isEqual:@"—"], @"Reset invalidates balance");
        NSCAssert(!AIProviderSnapshot(@{@"state": @"http_error", @"session": valid}, now), @"Error cannot resurrect a cached window");
        for (id invalid in @[@YES, @"0", @(-1), @101, NSNull.null]) {
            NSDictionary *bad = @{@"state": @"ok", @"remaining_percent": invalid, @"reset_at": @1794870000};
            NSCAssert(!AIProviderSnapshot(provider(bad, nil), now), @"Malformed percentages stay unknown");
        }
        for (id invalid in @[@YES, @"not a date", NSNull.null]) {
            NSDictionary *bad = @{@"state": @"ok", @"remaining_percent": @10, @"reset_at": invalid};
            NSCAssert(!AIProviderSnapshot(provider(bad, nil), now), @"Unbounded balances rejected");
        }
        for (NSNumber *balance in @[@0, @100]) {
            NSDictionary *window = @{@"state": @"ok", @"remaining_percent": balance, @"reset_at": @1794870000};
            NSDictionary *value = AIProviderSnapshot(provider(window, window), now);
            NSString *expected = [NSString stringWithFormat:@"%@%%", balance];
            NSCAssert([AIWindowRemaining(value[@"session"], now) isEqual:expected], @"Zero and full balances preserved");
        }
        NSDictionary *onlyWeekly = AIProviderSnapshot(provider(nil, valid), now);
        NSCAssert([AIWindowRemaining(onlyWeekly[@"session"], now) isEqual:@"—"], @"Weekly never substitutes for five-hour window");
        NSCAssert(!AIProviderSnapshot(NSNull.null, now), @"Invalid helper output is unavailable");
        puts("AI usage: snapshot and expiry checks passed");
    }
    return 0;
}
