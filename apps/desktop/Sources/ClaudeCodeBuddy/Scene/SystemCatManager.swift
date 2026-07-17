import SpriteKit
import Combine

/// 管理「系统猫」— 用于展示更新提示的单只特殊猫咪。
///
/// 系统猫使用 sessionId="__system_update__"，不进入 cats 字典、不被 SessionManager 管理。
/// 点击后 dismissVersion + 隐藏 + 打开设置关于页。
///
/// @MainActor（B3.2 加固）：start/showIfNeeded/handleClick 均主线程调用
/// （start 由 AppDelegate.applicationDidFinishLaunching 主线程触发；
/// handleClick 经 BuddyScene.simulateClick，调用方 QueryHandler.handle 已 @MainActor）。
@MainActor
final class SystemCatManager {
    static let shared = SystemCatManager()

    /// 系统猫的固定 sessionId。
    ///
    /// `nonisolated`：纯字符串字面量无需 actor 隔离，脱离 @MainActor 类隔离后
    /// 可被任意 nonisolated 上下文（BuddyScene.catAtPoint / AppDelegate.onClick 等）安全读取，
    /// 消除潜伏 Swift 6 strict mode 隔离报错（对照 MEMORY swift6-release-ci-masked-by-cache）。
    nonisolated static let systemCatSessionId = "__system_update__"

    private var systemCat: CatSprite?
    private var cancellables = Set<AnyCancellable>()
    private weak var scene: BuddyScene?

    private init() {}

    // MARK: - Public API

    /// 在指定场景中启动系统猫管理器（订阅 updateAvailable 事件）。
    func start(in scene: BuddyScene) {
        self.scene = scene

        // 订阅新版本事件：有新版本时显示系统猫
        EventBus.shared.updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.showIfNeeded()
            }
            .store(in: &cancellables)

        // 启动后立即检查是否需要显示
        showIfNeeded()
    }

    /// 检查 shouldShowSystemCat，若需要则创建并显示系统猫。
    func showIfNeeded() {
        guard UpdateChecker.shared.shouldShowSystemCat() else { return }
        guard systemCat == nil else { return }  // 已有系统猫则不重复创建
        guard let scene = scene else { return }

        let cat = CatSprite(sessionId: Self.systemCatSessionId)
        // 系统猫使用固定 mint 外观（绿色调，与更新主题搭配）
        let color = SessionColor.mint
        cat.configure(color: color, labelText: "更新")

        // 固定位置：活动区域右边缘附近
        let x = scene.activityBounds.upperBound - CatConstants.Visual.hitboxSize.width - 8
        let y = CatConstants.Visual.groundY
        cat.containerNode.position = CGPoint(x: x, y: y)

        scene.setSystemCat(cat)
        cat.enterScene(sceneSize: scene.size, activityBounds: scene.activityBounds)

        // 添加绿色更新徽章
        cat.addUpdateBadge()

        systemCat = cat

        BuddyLogger.shared.info("system cat shown", subsystem: "app", meta: [
            "version": UpdateChecker.shared.hasPendingUpdate ? "pending" : "latest"
        ])
    }

    /// 隐藏并移除系统猫。
    func hide() {
        guard let cat = systemCat else { return }
        cat.containerNode.removeFromParent()
        systemCat = nil
        BuddyLogger.shared.debug("system cat hidden", subsystem: "app")
    }

    /// 处理系统猫点击：dismiss 当前版本 + 隐藏系统猫 + 打开设置关于页。
    func handleClick() {
        UpdateChecker.shared.dismissCurrentVersion()
        hide()
        AppDelegate.shared?.openSettingsToAbout()
    }
}
