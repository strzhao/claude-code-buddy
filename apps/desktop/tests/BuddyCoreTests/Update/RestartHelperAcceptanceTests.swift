import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 修复「升级后 app 消失不再回来」bug 的核心契约。
///
/// 主根因（设计文档）：旧 `restartApp()` 用 `NSWorkspace.openApplication`
/// （`createsNewApplicationInstance` 默认 false）启动「还在运行的自己」→
/// LaunchServices launch 0 items → 紧接 `terminate` 杀唯一实例 → app 消失不回来。
/// 真机日志佐证：`LAUNCH: Asking CSUI to launch 0 items`。
///
/// 修复意图（本测试要验收的设计契约）：
///   restartApp 改为 detached `/bin/sh` helper 子进程模式，脚本含三要素：
///     1. `trap '' HUP` —— 兜底 controlling-terminal SIGHUP（Terminal 启动场景）
///     2. `pgrep -x ClaudeCodeBuddy` 轮询 —— 等旧实例真正退出，非固定 sleep
///     3. `open -n` —— 强制 LaunchServices 新建实例（-n 等价 createsNewApplicationInstance=true）
///   设计要求**抽取一个可测纯函数** `RestartHelper.buildScript(bundlePath:) -> String`
///   来构造这个脚本，使验收可在 headless 单测下断言脚本内容。
///
/// 信息隔离铁律：本测试**不读** Sources/ 下本次改动的任何实现文件
/// （AppDelegate.restartApp / RestartHelper.swift / SystemCatManager 等）。
/// 仅基于设计文档「应该实现什么」写断言。若 `RestartHelper` 类型/签名与设计不同，
/// 编译失败属预期 —— 编排器会让蓝队对齐，**测试不去读蓝队实现改自己**。
///
/// 驱动方式：det-logic（纯函数输入→输出断言，headless 可跑）。
/// det-machine 场景（P1-P6 真机日志/PID/socket）见仓库根同目录 checklist 注释块。
///
/// 命名前缀: test_RH<编号>_<场景>
final class RestartHelperAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    /// 简单 bundle path（无空格）。
    private static let plainBundlePath = "/Applications/ClaudeCodeBuddy.app"

    /// 含空格的 bundle path（验收双引号包裹）。
    private static let spacedBundlePath = "/x/My App/ClaudeCodeBuddy.app"

    // MARK: - 核心契约：三要素（设计文档修复意图的代码化）

    /// P0 契约：脚本必须含 `open -n`（非裸 `open`）。
    ///
    /// 这是**主根因修复的核心断言**。`-n` flag 强制 LaunchServices 新建实例
    /// （等价 `createsNewApplicationInstance=true`），而非复用「还在运行的自己」。
    /// 旧实现用 `NSWorkspace.openApplication`（默认 false）→ launch 0 items → app 消失。
    ///
    /// 断言：脚本里出现字面量 `open -n`，且其后的 path 被 LaunchServices 识别为
    /// 「强制新建实例」的命令。
    func test_RH01_scriptContainsOpenNForNewInstance() throws {
        let script = try buildScriptChecked(Self.plainBundlePath)

        XCTAssertTrue(script.contains("open -n"),
                      "脚本必须用 `open -n` 强制 LaunchServices 新建实例（主根因修复）。实际：\n\(script)")
        // 额外：禁止「裸 open 后跟 path」绕过 -n（避免蓝队退回旧 NSWorkspace.openApplication 等价路径）
        // 「open -n」优先匹配；「open "/...」或「open /...」算违规
        XCTAssertFalse(containsBareOpenFollowedByPath(script),
                       "脚本禁用裸 `open`（无 -n）启动 app —— 这正是被修复的根因。实际：\n\(script)")
    }

    /// P0 契约：脚本必须含 `pgrep -x ClaudeCodeBuddy` 轮询。
    ///
    /// 旧实现若用固定 `sleep N` 等旧实例退出：太短 → open 仍 launch 0 items（旧实例还在）；
    /// 太长 → 用户感知卡顿。正确做法是**轮询**旧实例是否真正退出。
    ///
    /// 注：`ClaudeCodeBuddy` 是可执行名（进程名）。若蓝队改了进程名常量，此断言会失败，
    /// 由编排器协调 —— 测试不读实现自动适配。
    func test_RH02_scriptContainsPgrepPollingForOldInstance() throws {
        let script = try buildScriptChecked(Self.plainBundlePath)

        XCTAssertTrue(script.contains("pgrep -x ClaudeCodeBuddy"),
                      "脚本必须用 `pgrep -x ClaudeCodeBuddy` 轮询旧实例退出（非固定 sleep）。实际：\n\(script)")
    }

    /// P0 契约：脚本必须含 `trap '' HUP`。
    ///
    /// 当 app 从 Terminal 启动（如 `open ClaudeCodeBuddy.app` 在 Terminal 里跑，
    /// 或开发期 `swift run`），helper 子进程会继承 controlling terminal。
    /// 旧实例 terminate 时 terminal 关闭/挂起 → SIGHUP 传给 helper → helper 没来得及
    /// open 新实例就被杀。`trap '' HUP` 让 helper 忽略 SIGHUP 兜底存活。
    func test_RH03_scriptContainsTrapHupForTerminalLaunchedApp() throws {
        let script = try buildScriptChecked(Self.plainBundlePath)

        XCTAssertTrue(script.contains("trap '' HUP") || script.contains("trap '' 1") || script.contains("trap -- '' HUP"),
                      "脚本必须含 `trap '' HUP` 兜底 controlling-terminal SIGHUP（Terminal 启动场景）。实际：\n\(script)")
    }

    // MARK: - bundle path 注入与双引号包裹（防空格路径分裂）

    /// P1 契约：含空格的 bundlePath 必须被双引号包裹注入脚本。
    ///
    /// 若 path 未引号包裹：`open -n /x/My App/ClaudeCodeBuddy.app` 会被 sh 词法
    /// 分裂成三个参数（`/x/My`、`App/ClaudeCodeBuddy.app`）→ open 报错 → app 不回来。
    /// 这是「fix 引入的 bug」的常见来源，必须断言。
    func test_RH04_scriptEmbedsBundlePathDoubleQuotedWithSpaces() throws {
        let path = Self.spacedBundlePath
        let script = try buildScriptChecked(path)

        let expected = "open -n \"\(path)\""
        XCTAssertTrue(script.contains(expected),
                      "含空格的 bundlePath 必须被双引号包裹：应出现 `\(expected)`。实际：\n\(script)")
    }

    /// P1 契约：bundlePath 原样注入（无转义/无 path 缩短）。
    ///
    /// 防止蓝队用 `\(bundlePath.path)` 误把 `.app` 当目录处理，或 trim 末尾斜杠等。
    func test_RH05_scriptEmbedsBundlePathVerbatim() throws {
        let path = Self.plainBundlePath
        let script = try buildScriptChecked(path)

        XCTAssertTrue(script.contains(path),
                      "bundlePath 必须原样出现在脚本中。期望含 `\(path)`。实际：\n\(script)")
    }

    // MARK: - 轮询上限（防无限循环）

    /// P1 契约：pgrep 轮询必须有上限（`[ $i -lt 50 ]` 或等价）。
    ///
    /// 若旧实例卡住不退出（uninterruptible sleep / 调试器挂起），无上限轮询会让
    /// helper 永远卡住，用户永远等不到 app 回来。必须有兜底退出 + 然后强制 open（哪怕
    /// launch 0 items，也比卡死强）或报错退出。
    ///
    /// 断言宽松：识别常见上限写法（`-lt N` / `-le N` / `while [ $i -lt`）。
    func test_RH06_scriptHasPollingUpperBound() throws {
        let script = try buildScriptChecked(Self.plainBundlePath)

        let hasBound = script.contains("-lt ") || script.contains("-le ")
                       || script.contains("MAX_WAIT") || script.contains("max_wait")
                       || script.contains("timeout")
        XCTAssertTrue(hasBound,
                      "pgrep 轮询必须有上限（如 `[ $i -lt 50 ]`），防旧实例卡死时 helper 永远循环。实际：\n\(script)")
    }

    // MARK: - detached helper 模式（调用约定契约）

    /// P2 契约：buildScript 返回的脚本应该是**可被 /bin/sh 执行的完整脚本**。
    ///
    /// 设计要求 restartApp 派发独立 `/bin/sh` 子进程跑这个脚本（detached）。
    /// 纯函数只构造脚本字符串，执行由调用方（restartApp）负责。验收 buildScript 的契约：
    /// 返回值非空 + 含 shebang 或可独立 sh -c 执行的语句集合。
    func test_RH07_buildScriptReturnsNonEmptyExecutableShellContent() throws {
        let script = try buildScriptChecked(Self.plainBundlePath)

        XCTAssertFalse(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "buildScript 必须返回非空脚本内容")
        // 三要素至少都出现（前面单测细判，此处整体契约）
        for needle in ["open -n", "pgrep", "trap"] {
            XCTAssertTrue(script.contains(needle),
                          "脚本整体应含三要素关键字 `\(needle)`。实际：\n\(script)")
        }
    }

    /// P2 契约：buildScript 是纯函数 —— 同输入同输出（无副作用、无全局状态依赖）。
    ///
    /// 防止蓝队把脚本构造和 Process 启动耦合在一个方法里（不可测）。
    /// 两次调同 path 应返回完全相同字符串。
    func test_RH08_buildScriptIsPureSameInputSameOutput() throws {
        let path = Self.plainBundlePath
        let script1 = try buildScriptChecked(path)
        let script2 = try buildScriptChecked(path)

        XCTAssertEqual(script1, script2,
                       "buildScript 必须是纯函数：同输入应返回完全相同输出（可独立单测）。")
    }

    /// P2 契约：不同 bundlePath 产出不同脚本（防忽略参数/硬编码 path）。
    func test_RH09_buildScriptReflectsDifferentBundlePaths() throws {
        let scriptA = try buildScriptChecked(Self.plainBundlePath)
        let scriptB = try buildScriptChecked(Self.spacedBundlePath)

        XCTAssertNotEqual(scriptA, scriptB,
                          "不同 bundlePath 必须产出不同脚本（防硬编码 path 忽略参数）")
        XCTAssertTrue(scriptA.contains(Self.plainBundlePath),
                      "scriptA 应含 pathA")
        XCTAssertTrue(scriptB.contains(Self.spacedBundlePath),
                      "scriptB 应含 pathB")
    }

    // MARK: - 类型存在性探针（信息隔离边界）

    /// 探针：RestartHelper 类型存在 + 有 buildScript(bundlePath:) 静态/实例方法。
    ///
    /// 若蓝队命名不同（如 `RestartScriptBuilder.build` / `AppRestarter.script`），
    /// 此处编译失败 → 编排器让蓝队对齐到设计文档命名 `RestartHelper.buildScript`，
    /// **测试不去读蓝队实现自动适配**。
    ///
    /// 调用方式设计文档未钉死 static vs instance。本测试用 instance 调用做探针；
    /// 若蓝队实现为 static，可让蓝队对齐到设计文档默认（推荐 static，纯函数语义）。
    private func buildScriptChecked(_ bundlePath: String) throws -> String {
        // 优先尝试 static 调用（设计文档推荐：纯函数语义）
        // 若蓝队实现为实例方法，编译失败由编排器对齐 —— 不读实现猜签名。
        return try RestartHelper.buildScript(bundlePath: bundlePath)
    }

    // MARK: - 否定断言 helper：检测「裸 open 后跟路径」（绕过 -n 的退化路径）

    /// 检测脚本里是否含「裸 `open `（非 `open -n`）后跟路径」的退化写法。
    ///
    /// 规则：按行扫，含 `open ` 但非 `open -n` / `open -a` / 注释行 → 判违规。
    /// 这是主根因修复的反向断言：**禁止**回到「NSWorkspace.openApplication 等价」的
    /// 裸 open（默认 createsNewApplicationInstance=false → launch 0 items）。
    private func containsBareOpenFollowedByPath(_ script: String) -> Bool {
        for rawLine in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 跳过注释
            if line.hasPrefix("#") { continue }
            // 找 `open ` 但非 `open -n`
            guard let range = line.range(of: "open ") else { continue }
            let afterOpen = String(line[range.upperBound...])
            // 允许 `open -n` / `open -a`（-a 指定 app，配合 -n 仍可）
            if afterOpen.hasPrefix("-n") || afterOpen.hasPrefix("-a") { continue }
            // 其他 `open <path>` 形式 → 违规
            if !afterOpen.isEmpty {
                return true
            }
        }
        return false
    }
}

// MARK: - 真机验收 checklist（P1-P6 det-machine 驱动命令）
//
// 以下为设计文档 §验收场景 的 det-machine 真机驱动命令清单，供 QA 阶段编排器执行。
// swift test 跑不到（需真机 LaunchServices / Process 派发），单测只守脚本内容契约（上方）。
//
// 前置（每条 P 前一次性准备）：
//   SKIP_FETCH_PLUGINS=1 make bundle
//   pkill -f ClaudeCodeBuddy 2>/dev/null; sleep 1
//   open apps/desktop/ClaudeCodeBuddy.app
//   sleep 2  # 等 app 起来 + socket listen
//   # 触发升级 UI：可用 buddy launcher debug open-settings about，或让 UpdateChecker
//   # 进 .available 态后点「立即升级」。以下命令假设升级刚触发完成。
//
// --- P1（真机点「立即升级」→ 新实例真的起来） ---
// 驱动：
//   OLD_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
//   # 触发升级（点 UI 或调 debug）—— 此处省略触发动作
//   sleep 8  # 等 helper 轮询 + open -n + 旧实例退出
//   /usr/bin/log show --predicate 'processImagePath CONTAINS "ClaudeCodeBuddy"' \
//       --last 1m --debug | grep -E "launch.*items|CSUI" > /tmp/p1_launch.log
//   NEW_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
// 断言（全过才算 P1 绿）：
//   1. grep -q "launch 1 items" /tmp/p1_launch.log && ! grep -q "launch 0 items" /tmp/p1_launch.log
//      （核心：旧根因是 launch 0 items，修复后必 launch 1 items）
//   2. [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]
//      （新 PID 非空且不同于旧 PID）
//   3. buddy log show --subsystem app --since 2m | grep -q "启动\|app 启动\|didFinishLaunching"
//      （新实例有启动日志）
//
// --- P2（重启后 socket 重建） ---
// 驱动（P1 完成后立刻跑）：
//   ls -la /tmp/claude-buddy.sock
//   buddy log show --subsystem socket --since 3m > /tmp/p2_socket.log
// 断言：
//   1. test -S /tmp/claude-buddy.sock
//      （socket 文件存在且是 Unix domain socket）
//   2. grep -qE "socket.*(listen|bind|启动)|listening" /tmp/p2_socket.log
//      （新实例有 socket listening 日志，证 socket server 重建）
//
// --- P3（重启后 buddy ping 成功） ---
// 驱动：
//   buddy ping; echo "EXIT=$?"
// 断言：
//   1. [ "$EXIT" = "0" ]
//      （ping 退出码 0，证 socket 通信全链路通）
//
// --- P4（settings 打开无 SIGABRT + 无新 .ips 崩溃报告） ---
// 驱动：
//   CRASH_BEFORE=$(ls -1 ~/Library/Logs/DiagnosticReports/ClaudeCodeBuddy*.ips 2>/dev/null | wc -l | tr -d ' ')
//   buddy launcher debug open-settings about; echo "EXIT=$?"
//   sleep 1
//   CRASH_AFTER=$(ls -1 ~/Library/Logs/DiagnosticReports/ClaudeCodeBuddy*.ips 2>/dev/null | wc -l | tr -d ' ')
// 断言：
//   1. [ "$EXIT" = "0" ]
//      （open-settings 命令退出 0，无 socket 报错）
//   2. [ "$CRASH_AFTER" = "$CRASH_BEFORE" ]
//      （无新 .ips 崩溃报告 —— 防 showSettings 调用链后台线程建 NSWindow → SIGABRT 回归）
//   3. osascript -e 'tell application "System Events" to count windows of process "ClaudeCodeBuddy"' ≥ 1
//      （设置窗真的打开了，证 showSettings 全链路在 @MainActor 下跑通）
//
// --- P5（压力：连续 3 次升级重启每次都出新实例） ---
// 驱动（循环 3 次）：
//   for i in 1 2 3; do
//     OLD_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
//     # 触发升级（略）
//     sleep 8
//     NEW_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
//     /usr/bin/log show --predicate 'processImagePath CONTAINS "ClaudeCodeBuddy"' \
//         --last 30s --debug | grep -E "launch.*items" > /tmp/p5_round_${i}.log
//     # 断言本轮
//     grep -q "launch 1 items" /tmp/p5_round_${i}.log || echo "P5 ROUND $i FAIL: no launch 1 items"
//     [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] || echo "P5 ROUND $i FAIL: no new PID"
//   done
// 断言：3 轮全过（每轮 launch 1 items + 新 PID），才算 P5 绿。
//
// --- P6（边角：Terminal 启动后升级重启，trap HUP 兜底 helper 存活） ---
// 驱动：
//   pkill -f ClaudeCodeBuddy 2>/dev/null; sleep 1
//   # 从 Terminal 直接启动（继承 controlling terminal）
//   apps/desktop/ClaudeCodeBuddy.app/Contents/MacOS/ClaudeCodeBuddy &
//   APP_PID=$!
//   sleep 2
//   OLD_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
//   # 触发升级（略）
//   sleep 8
//   /usr/bin/log show --predicate 'processImagePath CONTAINS "ClaudeCodeBuddy"' \
//       --last 30s --debug | grep -E "launch.*items|SIGHUP|trap" > /tmp/p6_terminal.log
//   NEW_PID=$(pgrep -x ClaudeCodeBuddy | head -1)
// 断言：
//   1. grep -q "launch 1 items" /tmp/p6_terminal.log
//      （Terminal 启动场景下 helper 仍能 launch 新实例 —— trap '' HUP 兜底生效）
//   2. [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]
//      （新实例起来，未被 terminal SIGHUP 连坐杀死）
