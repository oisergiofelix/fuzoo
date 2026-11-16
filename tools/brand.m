// Gera os assets visuais do fuzoo: ícone do app (.iconset) e imagens do site.
// Uso: make brand
//
// Marca: dois círculos que se cruzam — dois fusos, e a hora que eles dividem.

#import <AppKit/AppKit.h>

static NSColor *hex(unsigned v) {
    return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}
#define CREAM hex(0xF5F1E8)
#define INK hex(0x1A1A1A)
#define ACCENT hex(0xFF5A1F)

static void mark(NSRect r) {  // desenha a marca dentro de r (quadrado)
    CGFloat s = r.size.width, d = s * 0.52, off = s * 0.135;
    NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r));
    NSBezierPath *a = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - off - d / 2, c.y - d / 2, d, d)];
    NSBezierPath *b = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x + off - d / 2, c.y - d / 2, d, d)];
    [INK setFill];
    [a fill];
    [ACCENT setFill];
    [b fill];
    [NSGraphicsContext saveGraphicsState];
    [a addClip];
    [CREAM setFill];
    [b fill];
    [NSGraphicsContext restoreGraphicsState];
}

static void render(int w, int h, NSString *path, void (^draw)(NSRect)) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = g;
    g.imageInterpolation = NSImageInterpolationHigh;
    draw(NSMakeRect(0, 0, w, h));
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

static void icon(NSRect r) {  // grade de ícones do macOS: 824/1024 de conteúdo, cantos ~22,5%
    CGFloat s = r.size.width, inset = s * 100 / 1024, side = s - 2 * inset;
    NSRect body = NSMakeRect(inset, inset, side, side);
    NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:body xRadius:side * 0.225 yRadius:side * 0.225];
    [CREAM setFill];
    [sq fill];
    mark(NSInsetRect(body, side * 0.12, side * 0.12));
}

static NSFont *rounded(CGFloat size, NSFontWeight weight) {
    NSFont *f = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return [NSFont fontWithDescriptor:d size:size] ?: f;
}

static void text(NSString *s, NSFont *f, NSColor *c, NSPoint p) {
    [s drawAtPoint:p withAttributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : c}];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : @".";
        NSString *set = [out stringByAppendingPathComponent:@"fuzoo.iconset"];
        [NSFileManager.defaultManager createDirectoryAtPath:set withIntermediateDirectories:YES attributes:nil error:nil];
        for (int base = 16; base <= 512; base *= 2) {
            if (base == 64) continue;
            render(base, base, [set stringByAppendingFormat:@"/icon_%dx%d.png", base, base], ^(NSRect r) { icon(r); });
            render(base * 2, base * 2, [set stringByAppendingFormat:@"/icon_%dx%d@2x.png", base, base], ^(NSRect r) { icon(r); });
        }
        render(512, 512, [out stringByAppendingPathComponent:@"icon.png"], ^(NSRect r) { icon(r); });

        // Prévia social (GitHub, LinkedIn, X): 1280×640.
        render(1280, 640, [out stringByAppendingPathComponent:@"og.png"], ^(NSRect r) {
            [CREAM setFill];
            NSRectFill(r);
            mark(NSMakeRect(96, 300, 230, 230));
            text(@"fuzoo", rounded(150, NSFontWeightBlack), INK, NSMakePoint(370, 318));
            text(@"Two time zones. ~14 MB. Nothing else.", rounded(44, NSFontWeightMedium), hex(0x6B6560), NSMakePoint(100, 200));

            NSString *clock = @"CG 16:16  SP 17:16";
            NSFont *mono = [NSFont monospacedSystemFontOfSize:40 weight:NSFontWeightMedium];
            NSSize ts = [clock sizeWithAttributes:@{NSFontAttributeName : mono}];
            NSRect pill = NSMakeRect(100, 70, ts.width + 64, 76);
            [INK setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:38 yRadius:38] fill];
            text(clock, mono, CREAM, NSMakePoint(132, 70 + (76 - ts.height) / 2));
            text(@"macOS menu bar  ·  open source", rounded(30, NSFontWeightMedium), hex(0x9A938B),
                 NSMakePoint(NSMaxX(pill) + 36, 93));
        });
    }
    return 0;
}
