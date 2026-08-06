DEV := DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROJ := -project Spotion.xcodeproj -scheme Spotion -derivedDataPath build
VERSION ?= 0.0.0

.PHONY: gen build test install run clean reset-registration dist

gen:
	xcodegen generate

build: gen
	$(DEV) xcodebuild $(PROJ) -configuration Debug build

test: gen
	$(DEV) xcodebuild $(PROJ) test

install: gen
	$(DEV) xcodebuild $(PROJ) -configuration Release build
	rm -rf /Applications/Spotion.app
	ditto build/Build/Products/Release/Spotion.app /Applications/Spotion.app
	open /Applications/Spotion.app

run: build
	open build/Build/Products/Debug/Spotion.app

# Local replica of the CI packaging step (.github/workflows/release.yml),
# e.g. `make dist VERSION=9.9.9` for update-flow testing per docs/RELEASING.md
dist: gen
	$(DEV) xcodebuild $(PROJ) -configuration Release \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(VERSION) build
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent \
		build/Build/Products/Release/Spotion.app dist/Spotion-$(VERSION).zip

clean:
	rm -rf build dist Spotion.xcodeproj

# Reset hammer for Spotlight/App Intents registration issues (always verify
# against the /Applications copy)
reset-registration:
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Spotion.app
