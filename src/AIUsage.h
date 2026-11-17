#import <AppKit/AppKit.h>

// Sanitizes the helper's output. Missing or expired windows stay unavailable.
NSDictionary *AIProviderSnapshot(id raw, NSDate *received);
NSString *AIWindowRemaining(id window, NSDate *now);

@interface AIUsage : NSObject <NSMenuDelegate>
- (void)refreshIfNeeded;
- (void)stop;
@end
