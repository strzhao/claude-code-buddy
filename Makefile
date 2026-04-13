.PHONY: build run test test-acceptance test-all lint lint-fix format clean release bundle

build:
	swift build

run: build
	.build/debug/ClaudeCodeBuddy

test:
	swift test

test-acceptance: build
	bash tests/acceptance/run-all.sh

test-all: test test-acceptance

lint:
	swiftlint lint --strict

lint-fix:
	swiftlint --fix --format
	swiftlint lint --strict

format:
	swiftformat Sources/ Tests/

clean:
	swift package clean
	rm -rf .build/

release:
	swift build -c release --arch arm64

bundle: release
	@bash Scripts/bundle.sh
