import Foundation

// MARK: - SkinPackManifest

struct SkinPackManifest: Codable, Equatable {
    let id: String
    let name: String
    let author: String
    let version: String
    let previewImage: String?
    let spritePrefix: String
    let animationNames: [String]
    let canvasSize: [CGFloat]
    let bedNames: [String]
    let boundarySprite: String
    let foodNames: [String]
    let foodDirectory: String
    let spriteDirectory: String
    let menuBar: MenuBarConfig
    let sounds: SoundConfig?

    enum CodingKeys: String, CodingKey {
        case id             = "id"
        case name           = "name"
        case author         = "author"
        case version        = "version"
        case previewImage   = "preview_image"
        case spritePrefix   = "sprite_prefix"
        case animationNames = "animation_names"
        case canvasSize     = "canvas_size"
        case bedNames       = "bed_names"
        case boundarySprite = "boundary_sprite"
        case foodNames      = "food_names"
        case foodDirectory  = "food_directory"
        case spriteDirectory = "sprite_directory"
        case menuBar        = "menu_bar"
        case sounds         = "sounds"
    }
}

// MARK: - SoundConfig

struct SoundConfig: Codable, Equatable {
    let taskComplete: String?
    let permissionRequest: String?
    let directory: String?

    var resolvedDirectory: String { directory ?? "Sounds" }

    enum CodingKeys: String, CodingKey {
        case taskComplete     = "task_complete"
        case permissionRequest = "permission_request"
        case directory        = "directory"
    }
}

// MARK: - MenuBarConfig

struct MenuBarConfig: Codable, Equatable {
    let walkPrefix: String
    let walkFrameCount: Int
    let runPrefix: String
    let runFrameCount: Int
    let idleFrame: String
    let directory: String

    enum CodingKeys: String, CodingKey {
        case walkPrefix      = "walk_prefix"
        case walkFrameCount  = "walk_frame_count"
        case runPrefix       = "run_prefix"
        case runFrameCount   = "run_frame_count"
        case idleFrame       = "idle_frame"
        case directory       = "directory"
    }
}
