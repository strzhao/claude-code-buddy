import AppKit
import SwiftUI

final class LauncherHostingController: NSHostingController<LauncherInputView> {
    init(manager: LauncherManager) {
        super.init(rootView: LauncherInputView(manager: manager))
        // 让 SwiftUI 内 .frame(height: panelHeight(...)) 自动同步到 NSPanel.contentSize
        // 解决：panel frame 不更新导致候选/输出区画到 panel 外的虚空
        if #available(macOS 13.0, *) {
            sizingOptions = [.preferredContentSize]
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
