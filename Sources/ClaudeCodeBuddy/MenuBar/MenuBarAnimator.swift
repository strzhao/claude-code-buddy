import AppKit

/// 菜单栏动态像素猫动画控制器。
/// 根据活跃会话数切换动画：0→静止，1-2→走路，3+→跑步。活跃越多速度越快。
class MenuBarAnimator {

    // MARK: - Properties

    private weak var button: NSStatusBarButton?

    /// 走路动画帧（menubar-walk-{1..6}）— 少量活跃时使用（cat）
    private var walkFrames: [NSImage] = []
    /// 跑步动画帧（menubar-run-{1..5}）— 大量活跃时使用（cat）
    private var runFrames: [NSImage] = []
    /// 静止图标（cat）
    private var idleImage: NSImage?

    /// Rocket 模式对应的三组帧（nativecompose 不走 skin pack）。
    private var rocketWalkFrames: [NSImage] = []
    private var rocketRunFrames: [NSImage] = []
    private var rocketIdleImage: NSImage?

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

        // 两套帧：cat 走 skin manifest（可被用户皮肤包覆盖），rocket 走内置
        // 资源（不 skinnable）。MenuBarAnimator 根据 `mode` 挑选哪一套。
        (walkFrames, runFrames, idleImage) = loadCatFrames(iconSize: iconSize)
        (rocketWalkFrames, rocketRunFrames, rocketIdleImage) = loadRocketFrames(iconSize: iconSize)
    }

    private func loadCatFrames(iconSize: NSSize) -> (walk: [NSImage], run: [NSImage], idle: NSImage?) {
        let skin = SkinPackManager.shared.activeSkin
        let menuBarConfig = skin.manifest.menuBar
        let walk = loadFrameSequence(prefix: menuBarConfig.walkPrefix,
                                     count: menuBarConfig.walkFrameCount,
                                     size: iconSize, skin: skin)
        let run = loadFrameSequence(prefix: menuBarConfig.runPrefix,
                                    count: menuBarConfig.runFrameCount,
                                    size: iconSize, skin: skin)
        let idle: NSImage?
        if let url = skin.url(forResource: menuBarConfig.idleFrame,
                              withExtension: "png",
                              subdirectory: menuBarConfig.directory),
           let img = NSImage(contentsOf: url) {
            img.size = iconSize
            idle = img
        } else {
            idle = NSImage(systemSymbolName: "cat.fill",
                           accessibilityDescription: "Claude Code Buddy")
        }
        return (walk, run, idle)
    }

    /// Loads the rocket menubar set from the built-in bundle (Assets/Sprites/Menubar/
    /// menubar-rocket-*.png). These are NOT part of user skin packs — rocket
    /// mode is a system feature, not a customization surface.
    private func loadRocketFrames(iconSize: NSSize) -> (walk: [NSImage], run: [NSImage], idle: NSImage?) {
        let directory = "Assets/Sprites/Menubar"
        let walk = (1...6).compactMap { loadBundleImage("menubar-rocket-walk-\($0)", dir: directory, size: iconSize) }
        let run  = (1...5).compactMap { loadBundleImage("menubar-rocket-run-\($0)",  dir: directory, size: iconSize) }
        let idle = loadBundleImage("menubar-rocket-idle-1", dir: directory, size: iconSize)
            ?? NSImage(systemSymbolName: "airplane",
                       accessibilityDescription: "Claude Code Buddy (Rocket)")
        return (walk, run, idle)
    }

    private func loadBundleImage(_ name: String, dir: String, size: NSSize) -> NSImage? {
        guard let url = ResourceBundle.bundle.url(forResource: name,
                                                  withExtension: "png",
                                                  subdirectory: dir),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.size = size
        return img
    }

    /// Reload all sprites from the current skin (called during skin hot-swap).
    func reloadSprites() {
        loadSprites()
        if activeCatCount > 0 {
            switchFrames(for: activeCatCount)
        } else {
            applyIdleImage()
        }
    }

    private func loadFrameSequence(prefix: String, count: Int, size: NSSize, skin: SkinPack) -> [NSImage] {
        let menuBarDir = skin.manifest.menuBar.directory
        var frames: [NSImage] = []
        for i in 1...count {
            if let url = skin.url(forResource: "\(prefix)-\(i)",
                                  withExtension: "png",
                                  subdirectory: menuBarDir),
               let img = NSImage(contentsOf: url) {
                img.size = size
                frames.append(img)
            }
        }
        return frames
    }

    private func switchFrames(for count: Int) {
        let running = count >= runThreshold
        let newFrames: [NSImage]
        switch mode {
        case .cat:    newFrames = running ? runFrames       : walkFrames
        case .rocket: newFrames = running ? rocketRunFrames : rocketWalkFrames
        }
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
        button?.image = (mode == .rocket) ? rocketIdleImage : idleImage
    }

    // MARK: - Mode-aware icon

    /// Current entity mode. Changing this re-picks the frame set (walk/run/idle)
    /// so the menu bar icon swaps smoothly between the pixel cat and the
    /// pixel rocket without losing the animation cadence.
    var mode: EntityMode = .cat {
        didSet {
            guard oldValue != mode else { return }
            if activeCatCount > 0 {
                switchFrames(for: activeCatCount)
            } else {
                applyIdleImage()
            }
        }
    }
}
