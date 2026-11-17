APP     := fuzoo
BUNDLE  := build/$(APP).app
BIN     := $(BUNDLE)/Contents/MacOS/$(APP)
ARCHS   ?= -arch arm64 -arch x86_64
CFLAGS  := -Os -fobjc-arc -mmacosx-version-min=13.0 -Wall -Wextra -Wno-unused-parameter
LDFLAGS := -framework AppKit -framework ServiceManagement -Wl,-dead_strip
SIGN_IDENTITY ?= -

.PHONY: app run zip dmg release install brand check clean

app: $(BIN)

$(BIN): src/main.m src/AIUsage.m src/AIUsage.h Info.plist assets/$(APP).icns build/usage-bridge tools/UsageBridge-Info.plist
	@mkdir -p $(dir $@) $(BUNDLE)/Contents/Resources
	clang $(CFLAGS) $(ARCHS) src/main.m src/AIUsage.m $(LDFLAGS) -o $@
	strip $@
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp assets/$(APP).icns $(BUNDLE)/Contents/Resources/
	@mkdir -p $(BUNDLE)/Contents/Helpers/UsageBridge.app/Contents/MacOS
	cp build/usage-bridge $(BUNDLE)/Contents/Helpers/UsageBridge.app/Contents/MacOS/
	cp tools/UsageBridge-Info.plist $(BUNDLE)/Contents/Helpers/UsageBridge.app/Contents/Info.plist
	codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)" $(BUNDLE)/Contents/Helpers/UsageBridge.app
	codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)" $(BUNDLE)

run: app
	open $(BUNDLE)

zip: app
	cd build && rm -f $(APP).zip && ditto -c -k --keepParent $(APP).app $(APP).zip

dmg: app
	rm -rf build/dmg build/$(APP).dmg
	mkdir -p build/dmg && cp -R $(BUNDLE) build/dmg/ && ln -s /Applications build/dmg/Applications
	hdiutil create -quiet -volname $(APP) -srcfolder build/dmg -ov -format UDZO build/$(APP).dmg
	rm -rf build/dmg

release: zip dmg

# Distribution must use one stable Developer ID identity. Ad-hoc builds are only
# for local development and may legitimately trigger a Keychain prompt again.
.PHONY: production-check
production-check: check
	@test "$(SIGN_IDENTITY)" != "-" || (echo "Set SIGN_IDENTITY to a Developer ID Application certificate." >&2; exit 2)
	codesign --verify --deep --strict --verbose=2 $(BUNDLE)

check: app usage-check
	plutil -lint $(BUNDLE)/Contents/Info.plist
	codesign --verify --deep --strict $(BUNDLE)
	lipo $(BIN) -verify_arch arm64 x86_64
	lipo $(BUNDLE)/Contents/Helpers/UsageBridge.app/Contents/MacOS/usage-bridge -verify_arch arm64 x86_64

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/

# Regenera ícone e imagens do site a partir de tools/brand.m (não roda no build normal).
brand:
	@mkdir -p build/brand
	clang -fobjc-arc -framework AppKit tools/brand.m -o build/brand/brand
	build/brand/brand build/brand
	iconutil -c icns build/brand/$(APP).iconset -o assets/$(APP).icns
	cp build/brand/og.png build/brand/icon.png docs/

clean:
	rm -rf build

# One-shot usage helper. No launch agent, daemon or resident process.
build/usage-bridge: tools/usage-bridge.m Makefile
	@mkdir -p build
	clang $(CFLAGS) $(ARCHS) $< -framework AppKit -framework Security -lsqlite3 -o $@

.PHONY: usage-check
usage-check: build/usage-bridge
	build/usage-bridge --self-test
	clang $(CFLAGS) -I src tests/AIUsageTests.m src/AIUsage.m -framework AppKit -o build/ai-usage-tests
	build/ai-usage-tests

.PHONY: usage-authorizer
usage-authorizer: build/usage-bridge tools/UsageBridge-Info.plist
	@mkdir -p "build/Fuzoo Usage Bridge.app/Contents/MacOS"
	cp build/usage-bridge "build/Fuzoo Usage Bridge.app/Contents/MacOS/usage-bridge"
	cp tools/UsageBridge-Info.plist "build/Fuzoo Usage Bridge.app/Contents/Info.plist"
	codesign --force --sign - "build/Fuzoo Usage Bridge.app"
