DEV := DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROJ := -project Spotion.xcodeproj -scheme Spotion -derivedDataPath build

.PHONY: gen build test install run clean reset-registration

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

clean:
	rm -rf build Spotion.xcodeproj

# Reset hammer for Spotlight/App Intents registration issues (always verify
# against the /Applications copy)
reset-registration:
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Spotion.app
