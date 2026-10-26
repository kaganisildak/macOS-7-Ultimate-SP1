# Command Line Tools ship the Swift Testing macro plugin outside the default
# search path, so the SwiftPM build needs it passed explicitly.
SWIFT_PLUGINS := $(shell dirname "$$(xcrun -f swift 2>/dev/null)")/../lib/swift/host/plugins/testing

.PHONY: test clean chrome install-chrome shell signing-identity import-assets import-icons install uninstall wallpaper setup

# One test product per Tests/ directory, each run on its own so its result can be told apart.
# W7_BENCHMARKS=1 turns on Win7PerfTests' timing benchmarks (a bare `swift test` skips them).
TEST_PRODUCTS := $(notdir $(wildcard Tests/*Tests))
TEST_LOG := build/test-output.log

# A zero exit from swift test is not trusted: a test runner can exit 0 without finishing. The full
# output stays on screen and in $(TEST_LOG), and scripts/check-test-output.sh then requires a
# passing "Test run with N tests" line, and no failure, for every product.
test:
	mkdir -p build
	rm -f $(TEST_LOG)
	for p in $(TEST_PRODUCTS); do \
	  echo "=== test product: $$p" | tee -a $(TEST_LOG); \
	  W7_BENCHMARKS=1 swift test --no-parallel -Xswiftc -plugin-path -Xswiftc $(SWIFT_PLUGINS) --filter "^$$p\." 2>&1 | tee -a $(TEST_LOG); \
	done
	scripts/check-test-output.sh $(TEST_LOG) $(TEST_PRODUCTS)
	scripts/test_import.sh
	scripts/test_install.sh
	scripts/test_signing.sh
	scripts/test_setup.sh
	scripts/test_control_panel_ids.sh

CURSOR_PNGS := $(wildcard Assets/cursors/*.png)

# Plist consumed by -sectcreate: {name: {png, x, y}} for each Assets/cursors/<name>.png.
build/cursors.plist: $(CURSOR_PNGS) $(wildcard Assets/cursors/hotspots.txt)
	mkdir -p build
	rm -f $@
	plutil -create xml1 $@
	for f in $(CURSOR_PNGS); do \
	  n=$$(basename $$f .png); \
	  x=$$(awk -v n=$$n '$$1==n {print $$2}' Assets/cursors/hotspots.txt 2>/dev/null); \
	  y=$$(awk -v n=$$n '$$1==n {print $$3}' Assets/cursors/hotspots.txt 2>/dev/null); \
	  plutil -insert $$n -dictionary $@ || exit 1; \
	  plutil -insert $$n.png -data "$$(base64 -i $$f)" $@ || exit 1; \
	  plutil -insert $$n.x -integer $${x:-0} $@ || exit 1; \
	  plutil -insert $$n.y -integer $${y:-0} $@ || exit 1; \
	done

# The icon names the dylib reads (W7UserIconNames) and the user's PNGs among them.
ICON_NAMES := $(shell cat scripts/chrome-icon-names.txt)
ICON_PNGS := $(wildcard $(addprefix Assets/icons/,$(addsuffix .png,$(ICON_NAMES))))
ICON_SECTION_MAX := 2097152

# Plist consumed by -sectcreate (__DATA,__w7icons, read by W7UserIcons.m inside sandboxed apps too):
# {name: PNG data} for each name in scripts/chrome-icon-names.txt with an Assets/icons/<name>.png, converted to
# PNG by sips and scaled down to at most 128 px (never up). A symlink, a file over 2 MB or one sips cannot read
# is skipped, as the dylib would refuse it. Fails, naming the largest icons, when the plist is over 2 MB.
build/icons.plist: $(ICON_PNGS) scripts/chrome-icon-names.txt
	mkdir -p build/icons
	rm -f $@ build/icons/*.png
	plutil -create binary1 $@
	for f in $(ICON_PNGS); do \
	  n=$$(basename "$$f" .png); \
	  if [ -L "$$f" ] || [ $$(stat -f %z "$$f") -gt $(ICON_SECTION_MAX) ]; then echo "skip $$n: a symlink or over 2 MB" >&2; continue; fi; \
	  w=$$(sips -g pixelWidth "$$f" 2>/dev/null | awk '/pixelWidth/ {print $$2}'); \
	  h=$$(sips -g pixelHeight "$$f" 2>/dev/null | awk '/pixelHeight/ {print $$2}'); \
	  if [ -z "$$w" ] || [ -z "$$h" ]; then echo "skip $$n: not an image sips can read" >&2; continue; fi; \
	  if [ $$w -gt 128 ] || [ $$h -gt 128 ]; then fit="-Z 128"; else fit=""; fi; \
	  sips $$fit -s format png "$$f" --out "build/icons/$$n.png" >/dev/null 2>&1 || { echo "skip $$n: sips could not convert it" >&2; continue; }; \
	  plutil -insert "$$(printf '%s' "$$n" | sed 's/\./\\./g')" -data "$$(base64 -i "build/icons/$$n.png")" $@ || exit 1; \
	done
	size=$$(stat -f %z $@); \
	if [ $$size -gt $(ICON_SECTION_MAX) ]; then \
	  echo "build/icons.plist is $$size bytes, over the 2 MB __w7icons limit. Remove the largest from Assets/icons/:" >&2; \
	  ls -S build/icons | head -10 >&2; \
	  rm -f $@; exit 1; \
	fi

chrome:
	mkdir -p build
	rm -f build/cursors.plist build/icons.plist
	if [ -n "$(CURSOR_PNGS)" ]; then $(MAKE) build/cursors.plist; fi
	if [ -n "$(ICON_PNGS)" ]; then $(MAKE) build/icons.plist; fi
	clang -dynamiclib -fobjc-arc -arch arm64 -arch arm64e -mmacosx-version-min=15.0 \
	  -framework AppKit -framework QuartzCore -framework Carbon -framework CoreText -framework UniformTypeIdentifiers \
	  -I Sources/Win7Theme/include -I Sources/Win7ChromeCore/include \
	  Sources/Win7Theme/*.m Sources/Win7ChromeCore/*.m Sources/Win7ChromeLoader/*.m \
	  $$(test -f build/cursors.plist && echo -Wl,-sectcreate,__DATA,__w7cursors,build/cursors.plist) \
	  $$(test -f build/icons.plist && echo -Wl,-sectcreate,__DATA,__w7icons,build/icons.plist) \
	  -o build/Win7Chrome.dylib
	codesign -f -s - build/Win7Chrome.dylib

TWEAK_DIR ?= /var/ammonia/core/tweaks

# Needs Ammonia installed (manual prerequisite). Never run automatically. No sudo: the directory is
# world-writable. Install atomically (temp name, then mv -f): overwriting a loaded dylib in place
# invalidates its code signature and every newly launched app is killed.
install-chrome: chrome
	cp scripts/blacklist.txt build/Win7Chrome.dylib.blacklist
	cp build/Win7Chrome.dylib "$(TWEAK_DIR)/.Win7Chrome.dylib.new"
	mv -f "$(TWEAK_DIR)/.Win7Chrome.dylib.new" "$(TWEAK_DIR)/Win7Chrome.dylib"
	cp build/Win7Chrome.dylib.blacklist "$(TWEAK_DIR)/.Win7Chrome.dylib.blacklist.new"
	mv -f "$(TWEAK_DIR)/.Win7Chrome.dylib.blacklist.new" "$(TWEAK_DIR)/Win7Chrome.dylib.blacklist"

# Changes the Dock, menu bar, wallpaper, Finder and LaunchAgents. See README.md.
install:
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

# make setup [CHECK=1 | YES=1] [FORCE=1] [SKIP_TESTS=1]: read-only preflight (PASS/WARN/FAIL with the manual
# fixes), then asks before building + testing and before install (scripts/install.sh). CHECK=1 only checks
# (exit 1 on a FAIL); YES=1 asks nothing. Never sudo, csrutil changes or nvram writes. See README, Setup.
setup:
	scripts/setup.sh CHECK="$(CHECK)" YES="$(YES)" FORCE="$(FORCE)" SKIP_TESTS="$(SKIP_TESTS)"

SIGNING_IDENTITY_NAME := Win7Mac Local Signing

# The shell is signed with the stable local identity when find-identity lists it (trusted or not:
# codesign signs with an untrusted self-signed identity), so Accessibility and Screen Recording grants
# survive rebuilds; otherwise ad-hoc ("-"). `make shell CODESIGN_IDENTITY=...` overrides both.
ifndef CODESIGN_IDENTITY
CODESIGN_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -qF '"$(SIGNING_IDENTITY_NAME)"' && echo "$(SIGNING_IDENTITY_NAME)" || echo -)
endif

# Reminder printed when signing with the local identity: "Always Allow" would let any process of this user
# sign as com.win7mac.shell and inherit its permissions (README, Stable signing).
ifeq ($(CODESIGN_IDENTITY),$(SIGNING_IDENTITY_NAME))
SIGNING_REMINDER := echo 'Keychain prompt: answer "Allow", not "Always Allow" (see README, Stable signing).'
else
SIGNING_REMINDER := :
endif

# Creates "Win7Mac Local Signing" in the login keychain once (no sudo). Each `make shell` signing
# with it then asks for the keychain: answer "Allow".
signing-identity:
	scripts/make-signing-identity.sh

# Assembles build/Win7Shell.app from the release executable and Resources/Info.plist.
shell:
	swift build -c release --product Win7Shell -Xswiftc -plugin-path -Xswiftc $(SWIFT_PLUGINS)
	rm -rf build/Win7Shell.app
	mkdir -p build/Win7Shell.app/Contents/MacOS
	cp "$$(swift build -c release --product Win7Shell --show-bin-path)/Win7Shell" build/Win7Shell.app/Contents/MacOS/Win7Shell
	cp Resources/Info.plist build/Win7Shell.app/Contents/Info.plist
	mkdir -p build/Win7Shell.app/Contents/Resources
	@# Help and Support's README link; without README.md the link falls back to its "More support" topic.
	if [ -f README.md ]; then cp README.md build/Win7Shell.app/Contents/Resources/README.md; \
	else echo "warning: README.md is missing; Help and Support's README link will open its own topic" >&2; fi
	@echo "Signing Win7Shell.app with: $(CODESIGN_IDENTITY)"
	@$(SIGNING_REMINDER)
	codesign -f --timestamp=none -s "$(CODESIGN_IDENTITY)" build/Win7Shell.app

# make import-assets SRC=/path/to/Win7.iso   (or a folder with sources/install.wim, or a Windows tree)
# Needs 7zz on PATH. Extracts into Assets/ (git-ignored). Nothing is downloaded.
import-assets:
	@test -n "$(SRC)" || { echo "usage: make import-assets SRC=<Win7.iso | folder>" >&2; exit 1; }
	swift build -c release --product Win7AssetTool -Xswiftc -plugin-path -Xswiftc $(SWIFT_PLUGINS)
	scripts/import-win7-assets.sh "$(SRC)"

# make import-icons SRC=/path/to/imageres-icons.zip   (or a folder of .ico files) [FORCE=1] [PACK=<name>]
# Converts your own Windows icons (<dll>-#N.ico exports such as imageres-#3.ico, or icons named in the map) into Assets/icons/ (and
# the installed copy) using scripts/win7-icon-map.txt. FORCE=1 replaces icons that differ; without it a file
# you placed by hand is kept. W7_ASSET_TOOL=<binary> skips building Win7AssetTool (tests).
import-icons:
	@test -n "$(SRC)" || { echo "usage: make import-icons SRC=<icon pack .zip | folder of .ico files> [FORCE=1] [PACK=<name>]" >&2; exit 1; }
	if [ -z "$$W7_ASSET_TOOL" ]; then swift build -c release --product Win7AssetTool -Xswiftc -plugin-path -Xswiftc $(SWIFT_PLUGINS); fi
	FORCE="$(FORCE)" PACK="$(PACK)" scripts/import-icons.sh "$(SRC)"

# make wallpaper SRC=/path/to/img0.jpg   (or any image sips can read)
# Copies it to Assets/wallpaper.jpg (as JPEG) and, once installed, into the installed Assets and onto every desktop.
wallpaper:
	@test -n "$(SRC)" || { echo "usage: make wallpaper SRC=<image>" >&2; exit 1; }
	scripts/set-wallpaper.sh --import "$(SRC)"

clean:
	rm -rf .build build
