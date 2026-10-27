# Pingski build helpers. `make help` lists targets.

NAME      := pingski
APP_NAME  := Pingski
VERSION   := $(shell sed -n 's/.*pingskiVersion = "\(.*\)".*/\1/p' Sources/pingski/Version.swift)
PREFIX    ?= /usr/local
BUILD_DIR ?= build
CONFIG    ?= release
SWIFT_FLAGS ?=
APP       := $(BUILD_DIR)/$(APP_NAME).app
BIN_PATH  := $(shell swift build -c $(CONFIG) $(SWIFT_FLAGS) --show-bin-path 2>/dev/null)
PORT      ?= 7464
DIST_ARCH := --arch arm64 --arch x86_64
DIST_NAME := $(NAME)-$(VERSION)-macos-universal
DIST_DIR  := $(BUILD_DIR)/dist

# Launcher placed in bin/: resolves its own location so the install tree can live anywhere.
define LAUNCHER
#!/bin/sh
root="$$(dirname "$$(dirname "$$(readlink -f "$$0")")")"
exec "$$root/$(APP_NAME).app/Contents/MacOS/$(NAME)" "$$@"
endef
export LAUNCHER

.PHONY: help build bundle run test install uninstall dist openapi icon clean

help:
	@echo "make build      build the binary and $(APP)"
	@echo "make run        build then start the daemon (ARGS='--port 8080')"
	@echo "make test       run unit tests"
	@echo "make install    install into PREFIX (default /usr/local)"
	@echo "make uninstall  remove installed files from PREFIX"
	@echo "make dist       universal (arm64+x86_64) release archives in $(DIST_DIR)"
	@echo "make openapi    re-embed openapi/openapi.json into the Swift sources"
	@echo "make icon       regenerate Resources/AppIcon.icns"
	@echo "make clean      remove build artifacts"

build: bundle

$(BIN_PATH)/$(NAME): $(wildcard Sources/pingski/*.swift Sources/pingski/HTTP/*.swift) Package.swift
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

bundle: $(BIN_PATH)/$(NAME) Resources/Info.plist Resources/AppIcon.icns
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN_PATH)/$(NAME)" "$(APP)/Contents/MacOS/$(NAME)"
	sed 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - --identifier com.pingski.daemon "$(APP)"
	@echo "built $(APP) (v$(VERSION))"

run: bundle
	"$(APP)/Contents/MacOS/$(NAME)" $(ARGS)

# XCTest ships with Xcode, not the Command Line Tools; fall back to Xcode.app when needed.
XCODE_DEV := $(shell xcrun --find xctest >/dev/null 2>&1 || { [ -d /Applications/Xcode.app ] && echo /Applications/Xcode.app/Contents/Developer; })
test:
	$(if $(XCODE_DEV),DEVELOPER_DIR=$(XCODE_DEV)) swift test $(SWIFT_FLAGS)

install: bundle
	rm -rf "$(PREFIX)/$(APP_NAME).app"
	mkdir -p "$(PREFIX)/bin"
	cp -R "$(APP)" "$(PREFIX)/$(APP_NAME).app"
	printf '%s\n' "$$LAUNCHER" > "$(PREFIX)/bin/$(NAME)"
	chmod 755 "$(PREFIX)/bin/$(NAME)"
	@echo "installed $(PREFIX)/bin/$(NAME) -> $(PREFIX)/$(APP_NAME).app"

uninstall:
	rm -rf "$(PREFIX)/$(APP_NAME).app" "$(PREFIX)/bin/$(NAME)"

# Release archives: <name>.tar.gz (Pingski.app + bin/pingski launcher, used by the Homebrew formula)
# and <name>.zip (just Pingski.app, for drag-and-drop installs).
dist:
	$(MAKE) bundle SWIFT_FLAGS="$(DIST_ARCH) $(SWIFT_FLAGS)"
	rm -rf "$(DIST_DIR)"
	$(MAKE) install PREFIX="$(DIST_DIR)/$(DIST_NAME)" SWIFT_FLAGS="$(DIST_ARCH) $(SWIFT_FLAGS)"
	cp LICENSE README.md CHANGELOG.md "$(DIST_DIR)/$(DIST_NAME)/"
	tar -C "$(DIST_DIR)" -czf "$(DIST_DIR)/$(DIST_NAME).tar.gz" "$(DIST_NAME)"
	ditto -c -k --keepParent "$(DIST_DIR)/$(DIST_NAME)/$(APP_NAME).app" "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"
	rm -rf "$(DIST_DIR)/$(DIST_NAME)"
	cd "$(DIST_DIR)" && shasum -a 256 *.tar.gz *.zip | tee SHA256SUMS

openapi:
	./scripts/embed-openapi.sh

icon:
	swift scripts/make-icon.swift Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	rm -rf Resources/AppIcon.iconset

clean:
	rm -rf .build "$(BUILD_DIR)"
