APP     := fuzoo
BUNDLE  := build/$(APP).app
BIN     := $(BUNDLE)/Contents/MacOS/$(APP)
ARCHS   ?= -arch arm64 -arch x86_64
CFLAGS  := -Os -fobjc-arc -mmacosx-version-min=13.0 -Wall -Wextra -Wno-unused-parameter
LDFLAGS := -framework AppKit -framework ServiceManagement -Wl,-dead_strip

.PHONY: app run zip dmg release install brand check clean

app: $(BIN)

$(BIN): src/main.m Info.plist assets/$(APP).icns
	@mkdir -p $(dir $@) $(BUNDLE)/Contents/Resources
	clang $(CFLAGS) $(ARCHS) src/main.m $(LDFLAGS) -o $@
	strip $@
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp assets/$(APP).icns $(BUNDLE)/Contents/Resources/
	codesign --force --sign - $(BUNDLE)

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

check: app
	plutil -lint $(BUNDLE)/Contents/Info.plist
	codesign --verify --deep --strict $(BUNDLE)
	lipo $(BIN) -verify_arch arm64 x86_64

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
