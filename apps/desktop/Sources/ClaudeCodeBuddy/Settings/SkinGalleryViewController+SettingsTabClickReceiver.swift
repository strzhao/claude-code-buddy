import AppKit

// MARK: - SkinGalleryViewController + SettingsTabClickReceiver
//
// 独立文件声明 conformance —— `handleClickAt(windowPoint:)` 方法已在
// SkinGalleryViewController.swift 实现，这里仅追加协议声明。
// 保护 SkinGalleryViewController.swift 0 行改动（避免破坏 SkinGallerySnapshotTests）。
extension SkinGalleryViewController: SettingsTabClickReceiver {}
