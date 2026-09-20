# Command Line Tools only: no xcodebuild, no offline `metal`, no XCTest. See CLAUDE.md.
APP      := build/Recorder.app
CLT      := /Library/Developer/CommandLineTools/Library/Developer
# swift-testing ships with CLT but is not on the default search path.
TESTFLAGS := -Xswiftc -F -Xswiftc $(CLT)/Frameworks -Xlinker -F -Xlinker $(CLT)/Frameworks \
             -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib
# Stable identity keeps TCC grants (Screen Recording, Accessibility) across rebuilds. `-` = ad-hoc (grants reset every build).
SIGN_ID  ?= $(shell security find-identity -p codesigning | grep -q "Recorder Dev" && echo "Recorder Dev" || echo -)
CONFIG   ?= release
GALLERY_PNG ?= build/signal-ui-gallery.png

.PHONY: build test app run gallery gallery-png install uninstall clean cert
build:
	swift build -c $(CONFIG)

# make test                 -> all tests
# make test FILTER=timeMap  -> one test / suite
test:
	swift test $(TESTFLAGS) $(if $(FILTER),--filter $(FILTER))

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/Recorder $(APP)/Contents/MacOS/Recorder
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp -R Resources/Fonts $(APP)/Contents/Resources/
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	@if [ -d Resources/Wallpapers ]; then cp -R Resources/Wallpapers $(APP)/Contents/Resources/; fi
	@if [ -f Resources/click.caf ]; then cp Resources/click.caf $(APP)/Contents/Resources/; fi
	codesign --force --sign "$(SIGN_ID)" $(APP)

run: app
	open $(APP)

# Component gallery: interactive AppKit window, or a deterministic PNG for visual review.
gallery: app
	open -n $(APP) --args --ui-gallery

gallery-png: app
	$(APP)/Contents/MacOS/Recorder --selftest ui-kit-png $(GALLERY_PNG)
	open $(GALLERY_PNG)

install: app
	-pkill -x Recorder
	rm -rf /Applications/Recorder.app
	cp -R $(APP) /Applications/Recorder.app
	@echo "Installed /Applications/Recorder.app (signed with: $(SIGN_ID))"

uninstall:
	rm -rf /Applications/Recorder.app

clean:
	rm -rf .build build

# One-time: self-signed code-signing identity in the login keychain (asks for the keychain password once).
# Remove with: security delete-identity -c "Recorder Dev"
cert:
	@security find-identity -p codesigning | grep -q "Recorder Dev" && echo "Recorder Dev already exists" || ( \
	T=$$(mktemp -d) && cd $$T && \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout k.pem -out c.pem -subj "/CN=Recorder Dev" \
	  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null && \
	openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:recorder -name "Recorder Dev" && \
	security import id.p12 -k ~/Library/Keychains/login.keychain-db -P recorder -T /usr/bin/codesign && \
	rm -rf $$T && echo "Created identity: Recorder Dev" )
