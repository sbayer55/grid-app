APP = build/Grid.app
BIN = .build/release/Grid
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG = build/Grid-$(VERSION).dmg
STAGE = build/dmg

.PHONY: build run test release app dmg clean

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
	codesign --force --deep --sign - $(APP)
	@echo "→ $(APP)  (open build/Grid.app)"

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
