import AppKit

/// 菜单栏动态像素猫动画控制器。
/// 根据活跃会话数调节动画帧率；会话数为 0 时显示静止图标。
class MenuBarAnimator {

    // MARK: - Properties

    private weak var button: NSStatusBarButton?

    /// 步行动画帧（cat-walk-a-{1..8}）
    private var walkFrames: [NSImage] = []
    /// 静止图标（cat-idle-a-1 或降级 SF Symbol）
    private var idleImage: NSImage?

    private var currentFrame: Int = 0
    private var activeCatCount: Int = 0

    private var timer: DispatchSourceTimer?
    /// Track suspend state to safely resume before cancel in deinit.
    private var timerSuspended: Bool = true

    // MARK: - Init / Deinit

    init(button: NSStatusBarButton) {
        self.button = button
        loadSprites()
        setupTimer()
        applyIdleImage()
    }

    /// Note: Must be released on the main thread (guaranteed when owned by AppDelegate).
    deinit {
        // GCD requires a suspended source be resumed before cancel + dealloc.
        if timerSuspended {
            timer?.resume()
        }
        timer?.cancel()
    }

    // MARK: - Public Interface

    /// 更新活跃会话数，可在任意线程调用。
    func updateActiveCatCount(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasActive = self.activeCatCount > 0
            self.activeCatCount = count
            let isActive = count > 0

            if isActive && !wasActive {
                // 从静止切换到动画
                self.currentFrame = 0
                self.updateInterval(immediate: true)
                self.timer?.resume()
                self.timerSuspended = false
            } else if !isActive && wasActive {
                // 停止动画，显示静止图标
                self.timer?.suspend()
                self.timerSuspended = true
                self.applyIdleImage()
            } else if isActive {
                // 活跃数变化，调整速度（不立即跳帧）
                self.updateInterval(immediate: false)
            }
        }
    }

    // MARK: - Private Helpers

    private func loadSprites() {
        // 加载步行帧
        var frames: [NSImage] = []
        for i in 1...8 {
            let name = "cat-walk-a-\(i)"
            if let url = Bundle.module.url(forResource: name,
                                           withExtension: "png",
                                           subdirectory: "Assets/Sprites") {
                if let img = NSImage(contentsOf: url) {
                    img.size = NSSize(width: 18, height: 18)
                    frames.append(img)
                }
            }
        }
        walkFrames = frames

        // 加载静止图标
        if let url = Bundle.module.url(forResource: "cat-idle-a-1",
                                       withExtension: "png",
                                       subdirectory: "Assets/Sprites"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            idleImage = img
        } else {
            // 降级兜底：SF Symbol
            idleImage = NSImage(systemSymbolName: "cat.fill",
                                accessibilityDescription: "Claude Code Buddy")
        }
    }

    private func setupTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        // 初始处于 suspend 状态，等待 resume
        // DispatchSourceTimer 创建后默认已 suspend，需调用 resume 才启动
        timer = t
        // 不在此处 resume，由 updateActiveCatCount 决定
    }

    private func updateInterval(immediate: Bool = true) {
        guard activeCatCount > 0 else { return }
        let interval = max(0.04, 0.15 / Double(activeCatCount))
        let deadline: DispatchTime = immediate ? .now() : .now() + interval
        timer?.schedule(deadline: deadline, repeating: .milliseconds(Int(interval * 1000)))
    }

    private func tick() {
        guard !walkFrames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % walkFrames.count
        button?.image = walkFrames[currentFrame]
    }

    private func applyIdleImage() {
        button?.image = idleImage
    }
}
