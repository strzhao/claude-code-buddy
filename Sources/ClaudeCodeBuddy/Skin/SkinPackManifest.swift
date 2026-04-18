import Foundation

// MARK: - SkinVariant

/// A color variant within a skin pack. Overrides `spritePrefix` (and optionally
/// `bedNames` / `previewImage`) while sharing all other manifest fields.
struct SkinVariant: Codable, Equatable {
    let id: String
    let name: String
    let spritePrefix: String
    let previewImage: String?
    let bedNames: [String]?

    enum CodingKeys: String, CodingKey {
        case id           = "id"
        case name         = "name"
        case spritePrefix = "sprite_prefix"
        case previewImage = "preview_image"
        case bedNames     = "bed_names"
    }
}

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
    let variants: [SkinVariant]?
    /// Whether the sprite artwork faces right by default. Defaults to `true`.
    /// Set to `false` if sprites are drawn facing left.
    let spriteFacesRight: Bool?

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
        case variants       = "variants"
        case spriteFacesRight = "sprite_faces_right"
    }
}

// MARK: - Variant Helpers

extension SkinPackManifest {

    var hasVariants: Bool {
        guard let v = variants else { return false }
        return !v.isEmpty
    }

    func effectiveSpritePrefix(for variantId: String?) -> String {
        guard let variantId,
              let variant = variants?.first(where: { $0.id == variantId }) else {
            return spritePrefix
        }
        return variant.spritePrefix
    }

    func effectiveBedNames(for variantId: String?) -> [String] {
        guard let variantId,
              let variant = variants?.first(where: { $0.id == variantId }),
              let variantBeds = variant.bedNames else {
            return bedNames
        }
        return variantBeds
    }

    func effectivePreviewImage(for variantId: String?) -> String? {
        guard let variantId,
              let variant = variants?.first(where: { $0.id == variantId }),
              let variantPreview = variant.previewImage else {
            return previewImage
        }
        return variantPreview
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
