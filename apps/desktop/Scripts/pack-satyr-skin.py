#!/usr/bin/env python3
"""
pack-satyr-skin.py

Slices a Satyr sprite sheet (320x352, 32x32 cells) into individual animation
frames, generates placeholder assets (bed, boundary, food, menubar), writes
manifest.json, and produces a ready-to-upload skin pack directory.

Usage:
    python3 Scripts/pack-satyr-skin.py
"""

import json
import os
import shutil
from pathlib import Path

from PIL import Image

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SPRITE_SHEET = os.path.expanduser(
    "~/Downloads/SATYR_sprite_sheet /SPRITE_SHEET.png"
)
PORTRAIT = os.path.expanduser(
    "~/Downloads/SATYR_sprite_sheet /SPRITE_PORTRAIT.png"
)

OUTPUT_DIR = Path("satyr-skin")
SPRITES_DIR = OUTPUT_DIR / "Sprites"
MENUBAR_DIR = SPRITES_DIR / "Menubar"
FOOD_DIR = OUTPUT_DIR / "Food"

CELL_SIZE = 32
OUTPUT_SIZE = 48
PREFIX = "satyr"

# Row-to-animation mapping (row index in the 32x32 grid)
# max_frames: optional cap (row 6 is death/dissolve — only first 4 frames have the character)
ANIMATIONS = [
    {"name": "idle-a", "row": 0},   # Standing idle
    {"name": "walk-a", "row": 1},   # Walking
    {"name": "paw", "row": 2},      # Attack -> typing/thinking
    {"name": "walk-b", "row": 3},   # Heavy attack -> running
    {"name": "clean", "row": 4},    # Crouch/dodge -> grooming
    {"name": "scared", "row": 5},   # Hit reaction -> scared
    {"name": "jump", "row": 6, "max_frames": 4},  # Death anim, only first 4 frames usable
    {"name": "sleep", "row": 8},    # Low resting pose
    {"name": "idle-b", "row": 9},   # Object interaction -> blink/wake
]

MAX_COLS = 10
MAX_ROWS = 11


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def has_content(img: Image.Image, col: int, row: int) -> bool:
    """Check if a cell has any non-transparent pixels (alpha > 10)."""
    x = col * CELL_SIZE
    y = row * CELL_SIZE
    if x + CELL_SIZE > img.width or y + CELL_SIZE > img.height:
        return False
    cell = img.crop((x, y, x + CELL_SIZE, y + CELL_SIZE))
    if cell.mode != "RGBA":
        cell = cell.convert("RGBA")
    alpha = cell.split()[3]
    return alpha.getbbox() is not None


def count_frames(img: Image.Image, row: int) -> int:
    """Count non-empty frames in a row by scanning left-to-right."""
    count = 0
    for col in range(MAX_COLS):
        if has_content(img, col, row):
            count = col + 1
        else:
            break
    return count


def slice_frame(img: Image.Image, col: int, row: int) -> Image.Image:
    """Crop a 32x32 cell and upscale to 48x48 with nearest-neighbor."""
    x = col * CELL_SIZE
    y = row * CELL_SIZE
    cell = img.crop((x, y, x + CELL_SIZE, y + CELL_SIZE))
    return cell.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.NEAREST)


def make_menubar_frame(img: Image.Image, col: int, row: int) -> Image.Image:
    """Crop a 32x32 cell and scale to fit within 32x22 (menubar size)."""
    x = col * CELL_SIZE
    y = row * CELL_SIZE
    cell = img.crop((x, y, x + CELL_SIZE, y + CELL_SIZE))
    # Scale proportionally to fit in 32x22
    target_w, target_h = 32, 22
    scale = min(target_w / CELL_SIZE, target_h / CELL_SIZE)
    new_w = int(CELL_SIZE * scale)
    new_h = int(CELL_SIZE * scale)
    scaled = cell.resize((new_w, new_h), Image.NEAREST)
    # Center on 32x22 canvas
    canvas = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    offset_x = (target_w - new_w) // 2
    offset_y = (target_h - new_h) // 2
    canvas.paste(scaled, (offset_x, offset_y))
    return canvas


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print(f"Loading sprite sheet: {SPRITE_SHEET}")
    sheet = Image.open(SPRITE_SHEET).convert("RGBA")
    print(f"Sheet size: {sheet.width}x{sheet.height}")

    # Clean output directory
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)

    SPRITES_DIR.mkdir(parents=True)
    MENUBAR_DIR.mkdir(parents=True)
    FOOD_DIR.mkdir(parents=True)

    # -----------------------------------------------------------------------
    # 1. Slice animation frames
    # -----------------------------------------------------------------------
    animation_names = []
    frame_counts = {}

    for anim in ANIMATIONS:
        name = anim["name"]
        row = anim["row"]
        frames = count_frames(sheet, row)
        max_frames = anim.get("max_frames")
        if max_frames and frames > max_frames:
            frames = max_frames

        if frames == 0:
            print(f"  WARNING: No frames for {name} (row {row}), skipping")
            continue

        animation_names.append(name)
        frame_counts[name] = frames

        for i in range(frames):
            frame = slice_frame(sheet, i, row)
            path = SPRITES_DIR / f"{PREFIX}-{name}-{i + 1}.png"
            frame.save(path)

        print(f"  {name}: {frames} frames (row {row})")

    # Fallback: if idle-b has < 2 frames, use first 4 frames of idle-a
    if frame_counts.get("idle-b", 0) < 2 and "idle-a" in frame_counts:
        print("  idle-b fallback: using idle-a frames 1-4")
        n = min(4, frame_counts["idle-a"])
        for i in range(n):
            src = SPRITES_DIR / f"{PREFIX}-idle-a-{i + 1}.png"
            dst = SPRITES_DIR / f"{PREFIX}-idle-b-{i + 1}.png"
            shutil.copy2(src, dst)
        frame_counts["idle-b"] = n
        if "idle-b" not in animation_names:
            animation_names.append("idle-b")

    # -----------------------------------------------------------------------
    # 2. Menubar sprites
    # -----------------------------------------------------------------------
    # Walk (from walk-a row)
    walk_row = 1
    walk_frames = count_frames(sheet, walk_row)
    for i in range(walk_frames):
        mb = make_menubar_frame(sheet, i, walk_row)
        mb.save(MENUBAR_DIR / f"menubar-walk-{i + 1}.png")
    print(f"  menubar-walk: {walk_frames} frames")

    # Run (from walk-b row)
    run_row = 3
    run_frames = count_frames(sheet, run_row)
    for i in range(run_frames):
        mb = make_menubar_frame(sheet, i, run_row)
        mb.save(MENUBAR_DIR / f"menubar-run-{i + 1}.png")
    print(f"  menubar-run: {run_frames} frames")

    # Idle (from idle-a first frame)
    mb_idle = make_menubar_frame(sheet, 0, 0)
    mb_idle.save(MENUBAR_DIR / "menubar-idle-1.png")
    print("  menubar-idle: 1 frame")

    # -----------------------------------------------------------------------
    # 3. Bed sprite (use idle-a frame 1 as a simple bed placeholder)
    # -----------------------------------------------------------------------
    bed = slice_frame(sheet, 0, 0)
    bed.save(SPRITES_DIR / "bed-satyr.png")
    print("  bed-satyr: created from idle-a frame 1")

    # -----------------------------------------------------------------------
    # 4. Boundary sprite (use a cropped portion as decorative element)
    # -----------------------------------------------------------------------
    boundary = slice_frame(sheet, 0, 0)
    boundary.save(SPRITES_DIR / "boundary-satyr.png")
    print("  boundary-satyr: created from idle-a frame 1")

    # -----------------------------------------------------------------------
    # 5. Food sprite (use a frame as placeholder)
    # -----------------------------------------------------------------------
    food = slice_frame(sheet, 1, 0)
    food.save(FOOD_DIR / "food-satyr.png")
    print("  food-satyr: created from idle-a frame 2")

    # -----------------------------------------------------------------------
    # 6. Preview image (upscale portrait)
    # -----------------------------------------------------------------------
    print(f"Loading portrait: {PORTRAIT}")
    portrait = Image.open(PORTRAIT).convert("RGBA")
    # Upscale to ~96x96 area preserving aspect ratio
    scale = min(96 / portrait.width, 96 / portrait.height)
    new_w = int(portrait.width * scale)
    new_h = int(portrait.height * scale)
    preview = portrait.resize((new_w, new_h), Image.NEAREST)
    # Center on 96x96 canvas
    canvas = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
    canvas.paste(preview, ((96 - new_w) // 2, (96 - new_h) // 2))
    canvas.save(SPRITES_DIR / "preview.png")
    print(f"  preview.png: {new_w}x{new_h} centered on 96x96")

    # -----------------------------------------------------------------------
    # 7. manifest.json
    # -----------------------------------------------------------------------
    manifest = {
        "id": "satyr",
        "name": "Satyr",
        "author": "Claude Code Buddy",
        "version": "1.0.0",
        "preview_image": "preview.png",
        "sprite_prefix": PREFIX,
        "sprite_faces_right": True,
        "animation_names": animation_names,
        "canvas_size": [OUTPUT_SIZE, OUTPUT_SIZE],
        "bed_names": ["bed-satyr"],
        "boundary_sprite": "boundary-satyr",
        "food_names": ["food-satyr"],
        "food_directory": "Food",
        "sprite_directory": "Sprites",
        "menu_bar": {
            "walk_prefix": "menubar-walk",
            "walk_frame_count": walk_frames,
            "run_prefix": "menubar-run",
            "run_frame_count": run_frames,
            "idle_frame": "menubar-idle-1",
            "directory": "Sprites/Menubar",
        },
    }

    manifest_path = OUTPUT_DIR / "manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"\nManifest written to {manifest_path}")

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    total = sum(frame_counts.values())
    print(f"\nDone! {total} animation frames + menubar + assets")
    print(f"Output: {OUTPUT_DIR}/")
    print(f"\nTo upload:")
    print(f"  cd {OUTPUT_DIR} && zip -r ../satyr-skin.zip . && cd ..")
    print(f"  curl -X POST https://buddy.stringzhao.life/api/upload -F 'file=@satyr-skin.zip'")


if __name__ == "__main__":
    main()
