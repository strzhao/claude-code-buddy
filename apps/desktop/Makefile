.PHONY: build run run-raw run-bundle test test-acceptance test-all lint lint-fix format clean release bundle

build:
	swift build

# 走 dev-bundle.sh 包出 .app 再 open，避免裸 binary 触发 AppKit bundleProxy nil 异常
run: build
	@bash Scripts/dev-bundle.sh

run-bundle: run

# 裸 binary 调试用（部分 AppKit API 在无 Info.plist 下会崩，仅用于不依赖 bundle 的代码路径）
run-raw: build
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
	swift build -c release --arch arm64 --target buddy-cli

bundle: release
	@bash Scripts/bundle.sh
