APP = build/Grid.app
BIN = .build/release/Grid
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG = build/Grid-$(VERSION).dmg
STAGE = build/dmg

.PHONY: build run test release app dmg icon clean

build:
	swift build

run:
	swift run Grid

test:
	swift test

release:
	swift build -c release

app: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Grid
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP)
	@echo "→ $(APP)  (open build/Grid.app)"

# Regenerate Resources/AppIcon.icns from Scripts/make-icon.swift (the .icns is checked in).
icon:
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	swift Scripts/make-icon.swift build/AppIcon.iconset/icon_512x512@2x.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/AppIcon.iconset/icon_512x512@2x.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	done
	for s in 16 32 128 256; do \
		d=$$((s * 2)); sips -z $$d $$d build/AppIcon.iconset/icon_512x512@2x.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

dmg: app
	rm -rf $(STAGE) $(DMG)
	mkdir -p $(STAGE)
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname Grid -srcfolder $(STAGE) -fs HFS+ -format UDZO -ov $(DMG)
	rm -rf $(STAGE)
	hdiutil verify $(DMG)
	@echo "→ $(DMG)"

clean:
	rm -rf .build build
