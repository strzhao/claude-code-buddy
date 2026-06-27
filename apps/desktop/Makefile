.PHONY: build run run-raw run-bundle test test-raw test-only test-fast test-launcher test-acceptance test-all lint lint-fix format clean release bundle fetch-plugins fetch-plugins-local fix-plugin-perms

# C12 链式依赖（M8 qr shell 化后简化）：fetch-plugins → fix-plugin-perms → build/bundle。
# qr 已从编译型（qr-gen.swift + swiftc lipo）改为脚本型（qr-gen.sh），无需 build-qr-gen target。
# Make 同行 prerequisite 顺序不保证，故用链式（每个 target 依赖前一个）强制时序：
#   1. fetch-plugins: 从官方插件 monorepo git clone 拉取 plugins/ 源 + 生成 bundle marketplace.json
#   2. fix-plugin-perms: chmod shell 脚本可执行位（含 qr-gen.sh + qzh-exec）
#   3. build/bundle/release: swift build（SPM .copy 把含脚本的目录拷进 bundle）

# fetch-plugins: 从 buddy-official-plugins monorepo 拉取官方插件源（C1/C2/C3）。
# 失败兜底见 Scripts/fetch-plugins.sh（缓存 / 清晰错误）。SKIP_FETCH_PLUGINS=1 可跳过（本地调试）。
fetch-plugins:
	@bash Scripts/fetch-plugins.sh

# fetch-plugins-local: 本地开发循环 —— 直接从本地 clone 拉（免 GitHub 网络往返）。
# 默认指 ~/workspace/buddy-official-plugins（与 app repo 同级的 workspace clone），
# BUDDY_LOCAL_PLUGINS_DIR 可 override 指向任意本地 clone 路径。
# 实现：把 fetch-plugins.sh 的 BUDDY_OFFICIAL_PLUGINS_URL 设为 file:// URL（脚本已支持）。
# 适用：开发插件时改 monorepo → make fetch-plugins-local 立即生效，无需 git push。
# 默认值用 abspath 算（CURDIR = apps/desktop，../../../buddy-official-plugins = workspace 同级 clone）。
DEFAULT_LOCAL_PLUGINS_DIR := $(abspath $(CURDIR)/../../../buddy-official-plugins)
fetch-plugins-local:
	@LOCAL_DIR="$$BUDDY_LOCAL_PLUGINS_DIR"; \
	if [ -z "$$LOCAL_DIR" ]; then LOCAL_DIR="$(DEFAULT_LOCAL_PLUGINS_DIR)"; fi; \
	if [ ! -d "$$LOCAL_DIR/.git" ]; then \
		echo "[fetch-plugins-local] ERROR: 本地 monorepo 不存在: $$LOCAL_DIR" >&2; \
		echo "  设 BUDDY_LOCAL_PLUGINS_DIR=<path> override，或 clone https://github.com/strzhao/buddy-official-plugins" >&2; \
		exit 1; \
	fi; \
	echo "[fetch-plugins-local] 从本地 clone 拉: $$LOCAL_DIR"; \
	BUDDY_OFFICIAL_PLUGINS_URL="file://$$LOCAL_DIR" bash Scripts/fetch-plugins.sh

# fix-plugin-perms 直接依赖 fetch-plugins（M8 qr shell 化：不再有 build-qr-gen 编译步骤）。
# 修正 Marketplace 插件目录下 shell 脚本的可执行位（git 不保留权限位，CI/clone 后需重建）。
# 含 qr-gen.sh（M8 shell 化产物）+ qzh-exec。
PLUGIN_SCRIPTS := Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec
QR_GEN_SCRIPT := Sources/ClaudeCodeBuddy/Marketplace/plugins/qr/qr-gen.sh

fix-plugin-perms: fetch-plugins
	@echo "▶ 修正 Marketplace 插件脚本可执行位"
	@chmod 755 $(PLUGIN_SCRIPTS)
	@if [ -f "$(QR_GEN_SCRIPT)" ]; then chmod 755 $(QR_GEN_SCRIPT); echo "✓ $(QR_GEN_SCRIPT) → 755"; fi
	@echo "✓ $(PLUGIN_SCRIPTS) → 755"

# build 依赖 fix-plugin-perms（链式末端）：swift build 前 plugins/ 已填充 + 权限就绪。
build: fix-plugin-perms
	swift build


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

# I-NEW2：release 保留现有编译参数（两次 swift build 产出 app + buddy-cli 二进制），
# 依赖 fix-plugin-perms（M8 后链式：fetch → perms → release，无 build-qr-gen），否则 bundle 无 buddy CLI。
release: fix-plugin-perms
	swift build -c release --arch arm64
	swift build -c release --arch arm64 --target buddy-cli

bundle: release
	@bash Scripts/bundle.sh
