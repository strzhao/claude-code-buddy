.PHONY: build run test lint clean release bundle

build:
	swift build

run: build
	.build/debug/ClaudeCodeBuddy

test:
	swift test

lint:
	swiftlint lint --strict

clean:
	swift package clean
	rm -rf .build/

release:
	swift build -c release --arch arm64

bundle: release
	@bash Scripts/bundle.sh
