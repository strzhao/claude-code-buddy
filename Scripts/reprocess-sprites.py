#!/usr/bin/env python3
"""Reprocess cat sprite images: crop transparent padding and scale to 48x48.

Usage:
    python3 Scripts/reprocess-sprites.py              # Full batch processing
    python3 Scripts/reprocess-sprites.py --sample      # Process 5 sample images only
    python3 Scripts/reprocess-sprites.py --verify       # Verify all images are 48x48
    python3 Scripts/reprocess-sprites.py --restore      # Restore from backup
"""

import argparse
import glob
import os
import shutil
import sys

from PIL import Image

# Configuration
SPRITE_DIR = "Sources/ClaudeCodeBuddy/Assets/Sprites"
BACKUP_DIR = os.path.join(SPRITE_DIR, "backup")
TARGET_SIZE = (48, 48)
GLOBAL_BBOX = (11, 21, 38, 48)  # left, top, right, bottom
SAMPLE_FILES = [
    "cat-idle-a-1.png",
    "cat-walk-a-1.png",
    "cat-jump-2.png",
    "cat-sleep-1.png",
    "cat-scared-1.png",
]


def find_cat_sprites():
    """Find all cat sprite PNG files."""
    pattern = os.path.join(SPRITE_DIR, "cat-*.png")
    files = sorted(glob.glob(pattern))
    return files


def verify_bbox_safety(files):
    """Verify all files have content within the global bounding box.
    Returns (unsafe_list, transparent_list)."""
    left, top, right, bottom = GLOBAL_BBOX
    unsafe = []
    transparent = []
    for f in files:
        img = Image.open(f)
        bbox = img.getbbox()
        if bbox is None:
            transparent.append(f)
            continue
        if bbox[0] < left or bbox[1] < top or bbox[2] > right or bbox[3] > bottom:
            unsafe.append((f, f"content {bbox} exceeds global bbox {GLOBAL_BBOX}"))
    return unsafe, transparent


def backup_files(files):
    """Create backup of original sprite files."""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    for f in files:
        dst = os.path.join(BACKUP_DIR, os.path.basename(f))
        if not os.path.exists(dst):
            shutil.copy2(f, dst)
    print(f"Backed up {len(files)} files to {BACKUP_DIR}/")


def process_image(filepath):
    """Crop and scale a single sprite image."""
    img = Image.open(filepath)
    left, top, right, bottom = GLOBAL_BBOX
    cropped = img.crop((left, top, right, bottom))
    scaled = cropped.resize(TARGET_SIZE, Image.NEAREST)
    scaled.save(filepath)
    return filepath


def verify_output(files):
    """Verify all output files are TARGET_SIZE and well-filled."""
    all_ok = True
    for f in files:
        img = Image.open(f)
        if img.size != TARGET_SIZE:
            print(f"  FAIL: {os.path.basename(f)} size={img.size}, expected {TARGET_SIZE}")
            all_ok = False
            continue
        bbox = img.getbbox()
        if bbox is None:
            print(f"  FAIL: {os.path.basename(f)} is all transparent")
            all_ok = False
            continue
        # Check content fills most of the canvas
        content_w = bbox[2] - bbox[0]
        content_h = bbox[3] - bbox[1]
        fill_ratio = (content_w * content_h) / (TARGET_SIZE[0] * TARGET_SIZE[1])
        if fill_ratio < 0.5:
            print(f"  WARN: {os.path.basename(f)} content fill={fill_ratio:.0%} (bbox={bbox})")
    return all_ok


def main():
    parser = argparse.ArgumentParser(description="Reprocess cat sprite images")
    parser.add_argument("--sample", action="store_true", help="Process only 5 sample images")
    parser.add_argument("--verify", action="store_true", help="Verify all output images")
    parser.add_argument("--restore", action="store_true", help="Restore from backup")
    args = parser.parse_args()

    if args.restore:
        backup_files_list = glob.glob(os.path.join(BACKUP_DIR, "cat-*.png"))
        if not backup_files_list:
            print("No backup files found.")
            return
        for f in backup_files_list:
            dst = os.path.join(SPRITE_DIR, os.path.basename(f))
            shutil.copy2(f, dst)
            print(f"  Restored: {os.path.basename(f)}")
        print(f"Restored {len(backup_files_list)} files from backup.")
        return

    all_files = find_cat_sprites()
    if not all_files:
        print(f"No cat sprite files found in {SPRITE_DIR}/")
        sys.exit(1)

    if args.verify:
        print(f"Verifying {len(all_files)} sprite images...")
        if verify_output(all_files):
            print("All images OK.")
        else:
            print("Some images have issues (see above).")
            sys.exit(1)
        return

    files = all_files
    if args.sample:
        files = [os.path.join(SPRITE_DIR, f) for f in SAMPLE_FILES if os.path.exists(os.path.join(SPRITE_DIR, f))]
        print(f"Sample mode: processing {len(files)} files")

    # Step 1: Safety check
    print(f"Safety check: verifying all {len(files)} files within bbox {GLOBAL_BBOX}...")
    unsafe, transparent = verify_bbox_safety(files)
    if unsafe:
        print("UNSAFE: Some files have content outside the global bounding box:")
        for f, reason in unsafe:
            print(f"  {os.path.basename(f)}: {reason}")
        sys.exit(1)
    if transparent:
        print(f"  Skipping {len(transparent)} all-transparent files:")
        for f in transparent:
            print(f"    {os.path.basename(f)}")
        files = [f for f in files if f not in transparent]
    print(f"  All {len(files)} non-transparent files safe.")

    # Step 2: Backup
    backup_files(files)

    # Step 3: Process
    print(f"Processing {len(files)} files...")
    for f in files:
        process_image(f)
        print(f"  {os.path.basename(f)}: cropped {GLOBAL_BBOX[2]-GLOBAL_BBOX[0]}x{GLOBAL_BBOX[3]-GLOBAL_BBOX[1]} -> {TARGET_SIZE[0]}x{TARGET_SIZE[1]}")

    # Step 4: Verify
    print("Verifying output...")
    if verify_output(files):
        print("All output images verified OK.")
    else:
        print("WARNING: Some output images have issues.")

    print(f"\nDone! Processed {len(files)} sprite images.")


if __name__ == "__main__":
    main()
