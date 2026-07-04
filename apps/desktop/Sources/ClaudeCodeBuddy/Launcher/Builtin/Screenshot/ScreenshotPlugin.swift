import AppKit
import CoreGraphics
import Foundation

/// 截屏内置插件（C-SCREENSHOT-* 契约）。
///
/// launcher 输「截屏 / screenshot / jietu / 截图」→ Enter → 同步权限检查 → present 全屏 overlay →
/// 用户拖框选区 → Enter 确认 → 捕获选区 → **标注编辑器（cycle 2）** → 确认渲染合成 → PNG 写剪贴板（复用 CopyService）。
///
/// 本轮切片范围：区域选择 + 标注编辑器 + 复制（对标微信截屏核心）。**不做**：贴图、保存、select/move。
///
/// **架构（perform → overlay → onConfirm → handleConfirm → capture+copy，无死锁）**：
/// - perform 闭包（同步）：仅同步权限 preflight + `overlayController.present()`，**不阻塞、不捕获**；
/// - overlay `onConfirm(rect)`（async）：`confirm()` 用 `Task { @MainActor in await onConfirm(rect) }`
///   触发（事件驱动，cooperative），`_simulateConfirm()` 用 inline `await onConfirm(rect)`（测试确定性）；
/// - `handleConfirm(rect)` 是 onConfirm 的实现目标（internal），捕获+复制在主 actor 的 cooperative
///   await 上完成（main actor 在 await 期间释放，不死锁）。
///
/// **为何不再用 semaphore 桥接**（auto-fix SC-3 根因）：旧 `performCaptureSync` 用 `Task.detached +
/// semaphore.wait()` 把 async captureArea 桥进同步 perform，但生产 `SCScreenCapture`(@MainActor) 的
/// captureArea 需 hop 到 main actor，而 main 已被 semaphore 阻塞 → 死锁（30s 超时静默失败）。mock 测试
/// 只因 nonisolated spy 绕开 hop 而绿（patterns/2026-07-01 / patterns/2026-06-29 教训）。改用 overlay
/// onConfirm 异步回调，捕获在事件驱动的 Task 里 cooperative 完成，彻底消除 main-thread 阻塞。
///
/// 设计要点：
/// 1. **C-SCREENSHOT-KEYWORDS**：仅 {截屏, screenshot, jietu, 截图} hasPrefix 命中产出候选；
///    打分完全匹配 1000 / 前缀 800（对齐 SystemCommand）。裸词（如「图」「屏」）不误触。
/// 2. **C-PRIORITY**：`priority = 90`（低于 SystemCommand 100、高于 AppLauncher 0）。
/// 3. **C-BOUNDARY-BUILTIN-ONLY**：纯内置（全屏 overlay 必须进程内）。
/// 4. **C-CAPTURE-SEAM / C-COPY-SEAM**：`ScreenCapturing` + `CopyService` 可注入 Mock。
/// 5. **C-CONCURRENCY**：@MainActor 持有；捕获在 overlay onConfirm 的 cooperative Task 里。
/// 6. **C-LOGGING**：BuddyLogger subsystem "builtin"。
///
/// @MainActor：捕获 / 复制 / overlay 均主线程，规避 NSImage / 闭包 / CGImage 跨 actor Sendable 风险。
@MainActor
final class ScreenshotPlugin: BuiltinPlugin {

    static let shared = ScreenshotPlugin()

    // MARK: - BuiltinPlugin 契约

    let id = "screenshot"
    let priority: Int = 90   // C-PRIORITY：低于 SystemCommand(100)、高于 AppLauncher(0)
    let sectionTitle = "截屏"

    // C2：人话文案（设置页 / debug registry 展示）
    let summary = "截屏：输入「截屏」框选区域，自动复制到剪贴板"
    let description = "在输入框输入「截屏」「截图」「screenshot」回车，进入选区模式框选要截取的区域，确认后会自动复制到剪贴板，方便粘贴。按 Esc 取消。"

    // MARK: - 关键词集（C-SCREENSHOT-KEYWORDS）

    /// 小写比较。{截屏, screenshot, jietu, 截图}
    private static let keywords = ["截屏", "screenshot", "jietu", "截图"]

    // MARK: - 执行 seam（可注入，用于测试）

    private let capture: ScreenCapturing
    private let copy: CopyService
    /// 全屏 overlay 控制器（生产交互路径）。internal 供测试直接驱动 _simulateDrag/_simulateConfirm hook
    /// 与 `handleConfirm`（捕获+复制实现目标），无需触发 present GUI。
    let overlayController: ScreenshotOverlayController
    /// 标注编辑器控制器（cycle 2：捕获后 present）。internal 供测试驱动 _simulateDraw/_simulateConfirm hook。
    /// 单实例（每轮捕获复用同一引用，present 后 wire onConfirm/onCancel）。
    private(set) var editorController: ScreenshotAnnotationEditor?
    /// 标注编辑器工厂 seam（可注入，测试用 mock editor 验证 present 链路）。
    /// 默认 `ScreenshotAnnotationEditor(image:)`（@MainActor init → 用 optional+nil 默认 + init 内 resolve，
    /// 对齐 patterns/2026-06-19-swift-mainactor-shared-default-param-nonisolated 坑）。
    private let editorFactory: @MainActor (CGImage) -> ScreenshotAnnotationEditor
    /// 权限 preflight seam（可注入，测试用 `{ true }` 跳过真实 TCC）。默认 `ScreenRecordingPermission.isGrantedSync`。
    private let permissionPreflight: @MainActor () -> Bool
    /// 权限 request seam（可注入）。preflight 未授权时调此触发系统授权（`CGRequestScreenCaptureAccess`：
    /// 把 app 加入 TCC 列表 + 弹系统对话框）。默认 `ScreenRecordingPermission.requestIfNeededSync`。
    private let permissionRequest: @MainActor () -> Bool

    /// 测试注入用 init（对齐 SystemCommandPlugin/CalculatorPlugin 注入风格）。
    /// 参数名 `capture:` / `copy:` 与既有 Calculator(copyService:) / SystemCommand(locker:) 同语义。
    ///
    /// **@MainActor 默认参数坑**（对齐 `patterns/2026-06-19-swift-mainactor-shared-default-param-nonisolated`）：
    /// `SCScreenCapture()` / `ScreenshotOverlayController()` / `editorFactory` 是 @MainActor 隔离的构造，
    /// 不能作 nonisolated 默认参数表达式。故用 optional + nil 默认，在 @MainActor init 体（本 init 已 @MainActor）内 resolve。
    init(
        capture: ScreenCapturing? = nil,
        copy: CopyService = .shared,
        overlayController: ScreenshotOverlayController? = nil,
        editorFactory: (@MainActor (CGImage) -> ScreenshotAnnotationEditor)? = nil,
        permissionPreflight: (@MainActor () -> Bool)? = nil,
        permissionRequest: (@MainActor () -> Bool)? = nil
    ) {
        let controller = overlayController ?? ScreenshotOverlayController()
        self.capture = capture ?? SCScreenCapture()
        self.copy = copy
        self.overlayController = controller
        self.editorFactory = editorFactory ?? { image in ScreenshotAnnotationEditor(image: image) }
        self.permissionPreflight = permissionPreflight ?? ScreenRecordingPermission.isGrantedSync
        self.permissionRequest = permissionRequest ?? ScreenRecordingPermission.requestIfNeededSync
        // wire overlay 回调（生产路径：present → 用户拖框 → Enter → onConfirm → 捕获 → present editor）。
        // weak self 防插件→控制器→回调→插件 retain cycle。
        controller.onConfirm = { [weak self] rect in
            guard let self else { return }
            await self.handleConfirm(rect)
        }
        controller.onCancel = {
            BuddyLogger.shared.info(
                "screenshot 用户取消（ESC / 失焦），不捕获不写剪贴板",
                subsystem: "builtin"
            )
        }
    }

    // MARK: - actions(for:)（C-SCREENSHOT-KEYWORDS）

    /// 关键词匹配流程：
    /// - 空 query → `[]`
    /// - 命中关键词集合（hasPrefix）→ 单个候选 `score=1000`（完全）/ `800`（前缀）
    /// - 裸词（无前缀关系的词）→ `[]`
    func actions(for query: String) async -> [LauncherAction] {
        let normalized = query.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        let queryLower = normalized.lowercased()

        var bestScore = 0
        for keyword in Self.keywords {
            let kwLower = keyword.lowercased()
            if kwLower == queryLower {
                bestScore = max(bestScore, 1000)  // 完全匹配
            } else if kwLower.hasPrefix(queryLower) {
                bestScore = max(bestScore, 800)   // 前缀匹配
            }
        }

        guard bestScore > 0 else { return [] }

        let overlay = self.overlayController
        let checkPermission = self.permissionPreflight
        let requestPermission = self.permissionRequest

        let action = LauncherAction(
            id: "screenshot.capture",
            title: "截屏",
            subtitle: "框选区域 · 回车复制 · Esc 取消",
            icon: NSImage(systemSymbolName: "crop", accessibilityDescription: "截屏"),
            pluginId: self.id,
            score: bestScore,
            perform: {
                // 同步：权限 preflight → 未授权则触发系统 request（把 app 加入 TCC 列表 + 弹对话框）→ present overlay。
                // **不在此捕获**（捕获在 overlay.onConfirm → handleConfirm 异步完成，避免 main-thread 阻塞）。
                Self.startCaptureFlow(
                    overlayController: overlay,
                    permission: checkPermission,
                    request: requestPermission
                )
            }
        )
        return [action]
    }

    // MARK: - perform 实现：同步权限 preflight → 未授权触发 request → present overlay（不阻塞、不捕获）

    /// perform 闭包入口：三段权限流程 → present overlay。
    /// 捕获不在 perform（避免 main-thread 阻塞）；由 overlay.onConfirm 异步回调驱动。
    ///
    /// **三段权限流程**（修首次运行 app 不在 TCC 列表的 bug —— mock 测不出，真机抓到）：
    /// 1. `permission()`（preflight，纯查询）：已授权 → 直接 present overlay；
    /// 2. 未授权 → `request()`（`CGRequestScreenCaptureAccess`）：把 app 加入「屏幕录制」列表 + 弹系统对话框，
    ///    阻塞至用户响应；授权 → present overlay；
    /// 3. 被拒 / 已拒 → 引导跳系统设置（用户改主意后再来）。
    /// **关键**：不能只用 preflight 就跳设置 —— `CGPreflightScreenCaptureAccess` 不登记 app，用户在列表里
    /// 看不到 app 无从勾选；必须 `CGRequestScreenCaptureAccess` 触发登记。
    @MainActor
    private static func startCaptureFlow(
        overlayController: ScreenshotOverlayController,
        permission: @MainActor () -> Bool,
        request: @MainActor () -> Bool
    ) {
        BuddyLogger.shared.info(
            "screenshot perform → 权限检查 + present overlay",
            subsystem: "builtin"
        )

        // 1. 已授权 → 直接 present overlay
        if permission() {
            overlayController.present()
            return
        }

        // 2. 未授权 → 触发系统授权请求（登记 app + 弹对话框，阻塞至用户响应）
        BuddyLogger.shared.info(
            "screenshot preflight 未授权，触发系统授权请求（CGRequestScreenCaptureAccess）",
            subsystem: "builtin"
        )
        if request() {
            overlayController.present()
            return
        }

        // 3. 被拒 / 不可用 → 引导跳系统设置（不崩、不捕获）
        BuddyLogger.shared.warn(
            "screenshot 授权被拒 / 不可用，引导跳系统设置",
            subsystem: "builtin"
        )
        ScreenRecordingPermission.openSystemSettings()
    }

    // MARK: - overlay.onConfirm 实现：捕获 → 解码 CGImage → present 编辑器（async，cooperative，不死锁）

    /// overlay 确认选区后回调的目标实现（cycle 2 改造）：
    /// `captureArea(rect)` → PNG → 解码 CGImage → present `ScreenshotAnnotationEditor` →
    /// editor.onConfirm 渲染合成 + 复制；editor.onCancel 仅清理。
    ///
    /// 错误友好降级（权限拒绝 / 捕获失败 / 空数据 / 解码失败），不崩、不 present editor。
    ///
    /// internal 暴露：测试直接 `await plugin.handleConfirm(rect)` 确定性验证 capture + present editor，
    /// 无需触发 overlay present（避免 GUI 副作用）。
    @MainActor
    func handleConfirm(_ rect: CGRect) async {
        BuddyLogger.shared.info(
            "screenshot onConfirm 开始捕获选区",
            subsystem: "builtin",
            meta: ["rect": "\(rect)"]
        )

        let data: Data
        do {
            data = try await capture.captureArea(rect)
        } catch {
            BuddyLogger.shared.warn(
                "screenshot 捕获失败（友好降级，不 present editor）",
                subsystem: "builtin",
                meta: ["error": "\(error)"]
            )
            return
        }

        // PNG → CGImage
        guard let cgImage = Self.cgImage(from: data) else {
            BuddyLogger.shared.warn(
                "screenshot PNG→CGImage 解码失败（友好降级）",
                subsystem: "builtin",
                meta: ["bytes": data.count]
            )
            return
        }

        // 构造 + present 标注编辑器（cycle 2）
        let editor = editorFactory(cgImage)
        self.editorController = editor

        // wire editor 回调：onConfirm 渲染合成 → 复制；onCancel 仅清理
        editor.onConfirm = { [weak self] pngData in
            guard let self else { return }
            self.copy.copyImage(pngData)
            BuddyLogger.shared.info(
                "screenshot editor 确认 → 已复制合成 PNG 到剪贴板",
                subsystem: "builtin",
                meta: ["bytes": pngData.count]
            )
        }
        editor.onCancel = { [weak self] in
            self?.editorController = nil
            BuddyLogger.shared.info(
                "screenshot editor 用户取消（ESC），不复制",
                subsystem: "builtin"
            )
        }

        BuddyLogger.shared.info(
            "screenshot 捕获成功 → present 标注编辑器",
            subsystem: "builtin",
            meta: ["imgW": cgImage.width, "imgH": cgImage.height]
        )
        editor.present()
    }

    // MARK: - Helpers

    /// PNG `Data` → CGImage（用于喂 AnnotationKit 编辑器作 sourceImage）。
    private static func cgImage(from data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            pngDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
