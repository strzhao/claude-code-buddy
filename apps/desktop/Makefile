.PHONY: build run run-raw run-bundle test test-raw test-only test-fast test-acceptance test-all lint lint-fix format clean release bundle

build:
	swift build

# 走 dev-bundle.sh 包出 .app 再 open，避免裸 binary 触发 AppKit bundleProxy nil 异常
run: build
	@bash Scripts/dev-bundle.sh

run-bundle: run

# 裸 binary 调试用（部分 AppKit API 在无 Info.plist 下会崩，仅用于不依赖 bundle 的代码路径）
run-raw: build
	.build/debug/ClaudeCodeBuddy

# 全量测试，走看门狗：任何 flaky 死锁会在 TEST_TIMEOUT 内失败而非挂死数小时
test:
	bash Scripts/test-watchdog.sh

# 不带看门狗的裸 swift test（调试看门狗本身时用）
test-raw:
	swift test

# ⚡ 按测试类名过滤，迭代单个模块用（秒级）。
# 注意：--filter 匹配的是「测试类名」，不是文件名！
#   例：文件 LauncherRouterAcceptanceTests.swift 里的类叫 RouteDecisionEquatableTests
#   查类名：grep -rh 'final class .*: XCTestCase' Tests/
# 用法：make test-only FILTER=RouteDecisionEquatableTests
test-only:
	swift test --filter '$(FILTER)'

# ⚡ 快速逻辑回归：跳过窗口/快照/SpriteKit/socket 等重量级类（这些被 @MainActor
# 钉在主线程串行执行，是全量慢的主因）。SLOW_TESTS 为启发式列表，可按需增删。
SLOW_TESTS := Snapshot|LauncherWindow|LauncherVibrancy|LauncherTheme|LauncherHotkey|LauncherRoutingVisibility|LauncherFeedback|LauncherSubmitStateless|LauncherManagerAcceptance|LauncherManagerInstant|LauncherConstantsUI|CatSprite|CatSeparation|FoodAttraction|JumpExit|BedAndLabel|FacingDirection|BoundaryRecovery|PersistentBadge|SocketQuery|SocketProtocol|SessionManager|SessionIntegration
test-fast:
	swift test --skip '$(SLOW_TESTS)'

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
