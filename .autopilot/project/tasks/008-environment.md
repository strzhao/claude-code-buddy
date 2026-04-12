---
id: "008-environment"
depends_on: ["007-eventbus"]
---

# 008: Environment/Weather 框架 + EnvironmentResponder

## 目标
搭建环境/天气系统的协议框架和基础管理器。本次不实现具体天气效果（如雨、雪粒子），仅建立可扩展的架构骨架，使未来添加天气效果时不需要改动已有实体代码。

## 架构上下文
这是整个重构的最后一步，建立在 EventBus 之上。环境变化通过 EventBus 广播，所有实现 `EnvironmentResponder` 协议的实体自动收到通知并做出反应。

## 输入
- `Sources/ClaudeCodeBuddy/Event/EventBus.swift`（007 产出）
- `Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift`（006 产出）

## 输出
新文件：
```
Sources/ClaudeCodeBuddy/Environment/
├── EnvironmentResponder.swift   # 协议：实体响应环境变化
├── WeatherState.swift           # 天气状态枚举
├── TimeOfDay.swift              # 时段枚举
└── SceneEnvironment.swift       # 环境管理器
```
修改文件：
- `CatSprite.swift` —— 添加 `EnvironmentResponder` 遵循
- `BuddyScene.swift` —— 集成 SceneEnvironment
- `EventBus.swift` —— 确认 weatherChanged 和 timeOfDayChanged subject 已就绪

## 实现要点

### WeatherState

```swift
enum WeatherState: String, CaseIterable {
    case clear      // 晴天（默认）
    case cloudy     // 多云
    case rain       // 雨
    case snow       // 雪
    case wind       // 风

    /// 对实体行为的影响描述
    var behaviorModifier: BehaviorModifier {
        switch self {
        case .clear: return BehaviorModifier()
        case .rain: return BehaviorModifier(walkSpeedMultiplier: 0.7, idleSleepWeightBoost: 0.15)
        case .snow: return BehaviorModifier(walkSpeedMultiplier: 0.5, idleSleepWeightBoost: 0.25)
        case .wind: return BehaviorModifier(walkSpeedMultiplier: 1.2)
        case .cloudy: return BehaviorModifier(idleSleepWeightBoost: 0.05)
        }
    }
}

struct BehaviorModifier {
    var walkSpeedMultiplier: CGFloat = 1.0
    var idleSleepWeightBoost: Double = 0.0
    // 未来扩展：jumpHeightMultiplier, foodSpawnRateMultiplier, etc.
}
```

### TimeOfDay

```swift
enum TimeOfDay: String, CaseIterable {
    case morning    // 6:00 - 12:00
    case afternoon  // 12:00 - 18:00
    case evening    // 18:00 - 22:00
    case night      // 22:00 - 6:00

    static var current: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default: return .night
        }
    }
}
```

### EnvironmentResponder 协议

```swift
protocol EnvironmentResponder: AnyObject {
    /// 天气变化时调用
    func onWeatherChanged(_ weather: WeatherState)

    /// 时段变化时调用
    func onTimeOfDayChanged(_ time: TimeOfDay)
}

// 提供默认空实现，实体可选择性响应
extension EnvironmentResponder {
    func onWeatherChanged(_ weather: WeatherState) {}
    func onTimeOfDayChanged(_ time: TimeOfDay) {}
}
```

### SceneEnvironment 管理器

```swift
import Combine

class SceneEnvironment {
    private(set) var currentWeather: WeatherState = .clear
    private(set) var currentTimeOfDay: TimeOfDay = .current

    private var cancellables = Set<AnyCancellable>()
    private var timeCheckTimer: Timer?

    /// 注册到 EventBus
    func start() {
        // 每分钟检查时段变化
        timeCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkTimeOfDay()
        }
        checkTimeOfDay()
    }

    /// 手动设置天气（未来可由外部 API 或用户设置驱动）
    func setWeather(_ weather: WeatherState) {
        guard weather != currentWeather else { return }
        currentWeather = weather
        EventBus.shared.weatherChanged.send(weather)
    }

    private func checkTimeOfDay() {
        let newTime = TimeOfDay.current
        guard newTime != currentTimeOfDay else { return }
        currentTimeOfDay = newTime
        EventBus.shared.timeOfDayChanged.send(newTime)
    }

    func stop() {
        timeCheckTimer?.invalidate()
        timeCheckTimer = nil
    }
}
```

### CatSprite 遵循 EnvironmentResponder

```swift
extension CatSprite: EnvironmentResponder {
    func onWeatherChanged(_ weather: WeatherState) {
        // 更新行为参数
        let modifier = weather.behaviorModifier
        // 例如：movementComponent 的速度乘数
        movementComponent.speedMultiplier = modifier.walkSpeedMultiplier
        // idle 状态的睡眠权重调整
        if let idleState = stateMachine.currentState as? CatIdleState {
            idleState.sleepWeightBoost = modifier.idleSleepWeightBoost
        }
    }

    func onTimeOfDayChanged(_ time: TimeOfDay) {
        // 例如：夜间猫更倾向睡觉
        if time == .night {
            // 如果当前是 idle 且子状态不是 sleep，可能触发切换
        }
    }
}
```

### BuddyScene 集成

```swift
class BuddyScene: SKScene {
    private let environment = SceneEnvironment()
    private var cancellables = Set<AnyCancellable>()

    override func didMove(to view: SKView) {
        // ...existing setup...
        environment.start()

        // 天气变化通知所有实体
        EventBus.shared.weatherChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] weather in
                self?.entities.values.forEach { entity in
                    (entity as? EnvironmentResponder)?.onWeatherChanged(weather)
                }
            }
            .store(in: &cancellables)

        EventBus.shared.timeOfDayChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                self?.entities.values.forEach { entity in
                    (entity as? EnvironmentResponder)?.onTimeOfDayChanged(time)
                }
            }
            .store(in: &cancellables)
    }
}
```

### 扩展性验证
创建一个简单测试验证新实体可以响应环境事件：

```swift
func testEnvironmentResponderProtocol() {
    let cat = CatSprite(sessionId: "env-test")
    let env = SceneEnvironment()
    env.setWeather(.rain)
    // 验证 cat.movementComponent.speedMultiplier == 0.7
}
```

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test` 所有测试通过
- [ ] `WeatherState`、`TimeOfDay`、`EnvironmentResponder` 协议、`SceneEnvironment` 管理器均已实现
- [ ] CatSprite 实现 EnvironmentResponder 协议
- [ ] BuddyScene 通过 EventBus 将环境变化广播给所有实体
- [ ] `BehaviorModifier` 能影响猫的行为参数（至少 walkSpeed 和 idleSleepWeight）
- [ ] SceneEnvironment 自动检测时段变化
