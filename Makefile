# Command Line Tools only: no xcodebuild, no offline `metal`, no XCTest. See CLAUDE.md.
APP      := build/Recorder.app
VERSION  ?= $(shell scripts/version.sh version)
BUILD    ?= $(shell scripts/version.sh build)
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
	APP="$(APP)" BINARY=".build/$(CONFIG)/Recorder" VERSION="$(VERSION)" BUILD="$(BUILD)" SIGN_ID="$(SIGN_ID)" scripts/assemble-app.sh

run: app
	open $(APP)

# Component gallery: interactive AppKit window, or a deterministic PNG for visual review.
gallery: app
	open -n $(APP) --args --ui-gallery

gallery-png: app
	$(APP)/Contents/MacOS/Recorder --selftest ui-kit-png $(GALLERY_PNG)
	open $(GALLERY_PNG)

install:
	$(MAKE) cert
	$(MAKE) app APP=build/Recorder.app SIGN_ID="Recorder Dev"
	sh scripts/install-app.sh

uninstall:
	rm -rf /Applications/Recorder.app

clean:
	rm -rf .build build

# One-time: self-signed code-signing identity in the login keychain (asks for the keychain password once).
# Remove with: security delete-identity -c "Recorder Dev"
cert:
	@set -eu; \
	if security find-identity -p codesigning | grep -q '"Recorder Dev"'; then \
	  echo "Recorder Dev already exists"; \
	else \
	  cert_tmp=$$(mktemp -d); trap 'rm -rf "$$cert_tmp"' EXIT HUP INT TERM; cd "$$cert_tmp"; \
	  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout k.pem -out c.pem -subj "/CN=Recorder Dev" \
	    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"; \
	  /usr/bin/openssl pkcs12 -export -inkey k.pem -in c.pem -out id.p12 -passout pass:recorder -name "Recorder Dev" \
	    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1; \
	  security import id.p12 -k "$$HOME/Library/Keychains/login.keychain-db" -P recorder -T /usr/bin/codesign; \
	  echo "Created identity: Recorder Dev"; \
	fi
