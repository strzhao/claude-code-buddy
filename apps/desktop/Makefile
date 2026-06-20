.PHONY: build run run-raw run-bundle test test-raw test-only test-fast test-launcher test-acceptance test-all lint lint-fix format clean release bundle build-qr-gen fix-plugin-perms

# build 先构建 qr-gen universal binary（放回 Marketplace/plugins/qr/），
# 再 fix-plugin-perms（确保 shell 脚本可执行位，git 可能不保留），
# 再 swift build —— SPM .copy("Marketplace") 会把含二进制+脚本的目录拷进 bundle 资源。
# 时序关键：build-qr-gen / fix-plugin-perms 必须先于 swift build，否则 bundle 里产物缺失或权限错。
build: build-qr-gen fix-plugin-perms
	swift build

# 修正 Marketplace 插件目录下 shell 脚本的可执行位（git 不保留权限位，CI/clone 后需重建）。
# 当前覆盖：qzh-exec（qzh 插件，bash 脚本，command mode 可执行入口）。
# 与 build-qr-gen 同属「打包前资源准备」阶段，参考 qr 插件知识库 2026-05-26-spm-copy-executable-script-chmod-755。
PLUGIN_SCRIPTS := Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec

fix-plugin-perms:
	@echo "▶ 修正 Marketplace 插件脚本可执行位"
	@chmod 755 $(PLUGIN_SCRIPTS)
	@echo "✓ $(PLUGIN_SCRIPTS) → 755"

# qr-gen universal binary：CoreImage 二维码生成器（command mode 插件可执行文件）。
# arm64 + x86_64 双架构 + lipo 合并，保证 Intel/Apple Silicon 均可执行。
# 输出路径：Sources/ClaudeCodeBuddy/Marketplace/plugins/qr/qr-gen（被 .gitignore 排除，不入库）
# 引用知识库：2026-05-26-spm-copy-executable-script-chmod-755
QR_GEN_SRC := Sources/ClaudeCodeBuddy/Marketplace/plugins/qr/qr-gen.swift
QR_GEN_OUT := Sources/ClaudeCodeBuddy/Marketplace/plugins/qr/qr-gen

build-qr-gen:
	@echo "▶ 构建 qr-gen universal binary (arm64 + x86_64)"
	@build_dir=$$(mktemp -d); \
	swiftc -target arm64-apple-macosx14 -O -o $$build_dir/qr-gen-arm64 $(QR_GEN_SRC) -framework AppKit -framework CoreImage; \
	swiftc -target x86_64-apple-macosx14 -O -o $$build_dir/qr-gen-x86_64 $(QR_GEN_SRC) -framework AppKit -framework CoreImage; \
	lipo -create -output $(QR_GEN_OUT) $$build_dir/qr-gen-arm64 $$build_dir/qr-gen-x86_64; \
	chmod 755 $(QR_GEN_OUT); \
	rm -rf $$build_dir
	@echo "✓ qr-gen → $(QR_GEN_OUT)"


# 走 dev-bundle.sh 包出 .app 再 open，避免裸 binary 触发 AppKit bundleProxy nil 异常
run: build
	@bash Scripts/dev-bundle.sh

run-bundle: run

# 裸 binary 调试用（部分 AppKit API 在无 Info.plist 下会崩，仅用于不依赖 bundle 的代码路径）
run-raw: build
	.build/debug/ClaudeCodeBuddy

# 全量测试，走看门狗：任何 flaky 死锁会在 TEST_TIMEOUT 内失败而非挂死数小时。
# 先单独构建（不计入看门狗超时），再让看门狗只对「测试执行」计时——否则冷编译会被误判为挂死。
test:
	swift build --build-tests
	bash Scripts/test-watchdog.sh --skip-build

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

# ⚡ 只跑 launcher 子系统的全部测试（tests/BuddyCoreTests/Launcher/ 下所有测试类）。
# 开发 launcher 时用——不跑猫咪/皮肤/session/socket 等无关测试。
# 从目录动态生成 --filter（自动覆盖新增的 launcher 测试类，无需手维护清单）。
# 实现注意：
#  1) 用 bash 数组在单个子 shell 内构造并传 --filter（make 变量展开 70+ 个 --filter 不可靠）。
#  2) 直接前台跑 swift test，不经 Scripts/test-watchdog.sh——实测「看门狗后台运行 swift test
#     + 70+ 个 --filter + make recipe」三者叠加时 swift test 只会跑首个类就退出（前台直跑则正常，
#     全量 make test 无 filter 走看门狗也正常）。launcher 死锁已修（PluginExecutor terminationHandler），
#     这里无需看门狗兜底；需要墙钟保护时用全量 make test。
test-launcher:
	swift build --build-tests
	@bash -c 'args=(); while read -r c; do args+=(--filter "$$c"); done < <(grep -rhoE "class [A-Za-z0-9_]+ *: *XCTestCase" tests/BuddyCoreTests/Launcher/ | sed -E "s/class ([A-Za-z0-9_]+).*/\1/" | sort -u); echo "▶ 只跑 launcher：$$(($${#args[@]}/2)) 个测试类"; swift test --skip-build "$${args[@]}"'

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
