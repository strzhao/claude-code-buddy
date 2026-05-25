import AppKit
import SwiftUI

final class LauncherHostingController: NSHostingController<LauncherInputView> {
    init(manager: LauncherManager) {
        super.init(rootView: LauncherInputView(manager: manager))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
