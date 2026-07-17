import Foundation

/// 升级后重启 app 的 detached helper 脚本构造器（纯函数，可单测）。
///
/// 根因（真机日志已锁定）：`AppDelegate.restartApp()` 旧实现用
/// `NSWorkspace.openApplication`（`createsNewApplicationInstance` 默认 false）启动
/// "还在运行的自己" → LaunchServices `launch 0 items` → 紧接 `terminate` 杀唯一实例
/// → app 消失。改用 detached `/bin/sh` 子进程：父 terminate→exit 后由 launchd 收养继续执行，
/// `open -n` 强制 LaunchServices 新建实例（等价 `createsNewApplicationInstance=true`，
/// 杜绝 bundle id 残存登记时复用旧实例）。
///
/// 红队断言对象（脚本三要素，改动措辞会导致红队验收失败）：
///   1. `trap '' HUP` —— 兜底 controlling-terminal 场景，父退出 SIGHUP 不杀子。
///   2. `pgrep -x ClaudeCodeBuddy` 轮询 —— 等旧实例真正退出（上限 50×0.1s=5s 兜底）。
///   3. `open -n` —— 强制 LaunchServices 新建实例。
enum RestartHelper {
    /// 构造 detached 重启脚本。pgrep 上限 50×0.1s=5s 兜底。
    ///
    /// - Parameter bundlePath: app bundle 绝对路径（`Bundle.main.bundleURL.path`）。
    /// - Returns: 可直接喂给 `/bin/sh -c` 的脚本字符串。
    static func buildScript(bundlePath: String) -> String {
        return """
trap '' HUP
i=0
while pgrep -x ClaudeCodeBuddy >/dev/null 2>&1 && [ $i -lt 50 ]; do
  sleep 0.1
  i=$((i+1))
done
sleep 0.3
open -n "\(bundlePath)"
"""
    }
}
