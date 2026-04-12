import AppKit

/// 菜单栏动态像素猫动画控制器。
/// 根据活跃会话数切换动画：0→静止，1-2→走路，3+→跑步。活跃越多速度越快。
class MenuBarAnimator {

    // MARK: - Properties

    private weak var button: NSStatusBarButton?

    /// 走路动画帧（menubar-walk-{1..6}）— 少量活跃时使用
    private var walkFrames: [NSImage] = []
    /// 跑步动画帧（menubar-run-{1..5}）— 大量活跃时使用
    private var runFrames: [NSImage] = []
    /// 静止图标（menubar-idle-1 或降级 SF Symbol）
    private var idleImage: NSImage?

    private var currentFrame: Int = 0
    private var activeCatCount: Int = 0
    /// 当前使用的帧序列（walk 或 run），避免每次 tick 判断
    private var activeFrames: [NSImage] = []

    private var timer: DispatchSourceTimer?
    /// Track suspend state to safely resume before cancel in deinit.
    private var timerSuspended: Bool = true

    /// 跑步动画的活跃猫阈值
    private let runThreshold = 3

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
            let oldCount = self.activeCatCount
            self.activeCatCount = count
            let isActive = count > 0

            if isActive && !wasActive {
                // 从静止切换到动画
                self.switchFrames(for: count)
                self.updateInterval(immediate: true)
                self.timer?.resume()
                self.timerSuspended = false
            } else if !isActive && wasActive {
                // 停止动画，显示静止图标
                self.timer?.suspend()
                self.timerSuspended = true
                self.applyIdleImage()
            } else if isActive {
                // 活跃数变化：检查是否需要切换 walk↔run
                let wasRunning = oldCount >= self.runThreshold
                let shouldRun = count >= self.runThreshold
                if wasRunning != shouldRun {
                    self.switchFrames(for: count)
                }
                self.updateInterval(immediate: false)
            }
        }
    }

    // MARK: - Private Helpers

    private func loadSprites() {
        // 菜单栏高度 22pt，图标用满高度，宽度按比例
        let iconHeight: CGFloat = 22
        let iconWidth: CGFloat = 32  // 50:34 ≈ 32:22

        let iconSize = NSSize(width: iconWidth, height: iconHeight)

        // 加载走路帧
        walkFrames = loadFrameSequence(prefix: "menubar-walk", count: 6, size: iconSize)

        // 加载跑步帧
        runFrames = loadFrameSequence(prefix: "menubar-run", count: 5, size: iconSize)

        // 加载静止图标
        if let url = Bundle.module.url(forResource: "menubar-idle-1",
                                       withExtension: "png",
                                       subdirectory: "Assets/Sprites/Menubar"),
           let img = NSImage(contentsOf: url) {
            img.size = iconSize
            idleImage = img
        } else {
            idleImage = NSImage(systemSymbolName: "cat.fill",
                                accessibilityDescription: "Claude Code Buddy")
        }
    }

    private func loadFrameSequence(prefix: String, count: Int, size: NSSize) -> [NSImage] {
        var frames: [NSImage] = []
        for i in 1...count {
            if let url = Bundle.module.url(forResource: "\(prefix)-\(i)",
                                           withExtension: "png",
                                           subdirectory: "Assets/Sprites/Menubar"),
               let img = NSImage(contentsOf: url) {
                img.size = size
                frames.append(img)
            }
        }
        return frames
    }

    private func switchFrames(for count: Int) {
        let newFrames = count >= runThreshold ? runFrames : walkFrames
        if activeFrames.count != newFrames.count || activeFrames.first !== newFrames.first {
            activeFrames = newFrames
            currentFrame = 0
        }
    }

    private func setupTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
    }

    private func updateInterval(immediate: Bool = true) {
        guard activeCatCount > 0 else { return }
        let interval = max(0.04, 0.15 / Double(activeCatCount))
        let deadline: DispatchTime = immediate ? .now() : .now() + interval
        timer?.schedule(deadline: deadline, repeating: .milliseconds(Int(interval * 1000)))
    }

    private func tick() {
        guard !activeFrames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % activeFrames.count
        button?.image = activeFrames[currentFrame]
    }

    private func applyIdleImage() {
        button?.image = idleImage
    }
}
