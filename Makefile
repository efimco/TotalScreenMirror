# Rebuilding is a routine chore here, not a one-off: with a free Apple Developer
# account the signature expires after 7 days and the app has to be reinstalled.
# `make install` is that whole cycle in one command.

PROJECT := TotalScreenMirror.xcodeproj
TARGET  := TotalScreenMirror
CONFIG  := Debug
APP     := build/$(CONFIG)-iphoneos/$(TARGET).app

# CoreSimulator and the destination resolver read the system-wide active developer
# directory, so `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` is
# still worth doing. This override is enough for building and installing without it.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

# Building by -target with -sdk iphoneos rather than by -scheme with -destination:
# scheme-based destination resolution needs a registered simulator runtime, which is
# unrelated to shipping a build to a physical device.
XCB := xcodebuild -project $(PROJECT) -target $(TARGET) -configuration $(CONFIG) \
       -sdk iphoneos -allowProvisioningUpdates

.PHONY: help generate build install devices clean

help:
	@echo "make build                  - build signed for device"
	@echo "make install DEVICE=<id>    - build and install (see 'make devices')"
	@echo "make devices                - list connected devices"
	@echo "make generate               - regenerate the Xcode project from project.yml"
	@echo "make clean                  - remove build output"

generate:
	xcodegen generate

build: generate
	$(XCB) build

devices:
	@xcrun devicectl list devices

install: build
	@test -n "$(DEVICE)" || (echo "Set DEVICE=<identifier>; run 'make devices' to find it." && exit 1)
	xcrun devicectl device install app --device $(DEVICE) $(APP)

clean:
	rm -rf build
