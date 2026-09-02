#!/bin/bash
# fetch-plugins.sh — build-time 把官方插件源打进 app bundle（C1/C2/C3）。
#
# 2026-09-02 起：官方插件 monorepo（strzhao/buddy-official-plugins）已 subtree 收编进本仓
# `plugins/`（物理同仓，插件仍不编进 app —— bundle seed 双轨机制不变）。数据流：
#   1. rsync <repo-root>/plugins/ → Sources/ClaudeCodeBuddy/Marketplace/plugins/（覆盖填充）
#   2. 读 marketplace.json，把 gitSubdir source 改写为 localSubdir（./plugins/<name>），
#      生成 bundle 专用 marketplace.json（离线 seed 用，C3 双轨）
#   3. 写 .fetched-from 标记（in-repo@<commit>，排查用）
#
# 时序（C12，M8 qr shell 化后简化）：Makefile 链式 fetch-plugins → fix-plugin-perms → build/bundle。
# 本脚本由 Makefile `fetch-plugins` target 调用，在 swift build 前执行。
# 同仓拷贝零网络往返，原 git clone + 缓存兜底（C8）随跨仓 fetch 一并退役。
set -euo pipefail

# MARK: - 路径常量

# app 仓库根（Scripts/ 的上两级 = apps/desktop 的上两级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DESKTOP_DIR/../.." && pwd)"
PLUGINS_DIR="$DESKTOP_DIR/Sources/ClaudeCodeBuddy/Marketplace/plugins"
MARKETPLACE_JSON="$DESKTOP_DIR/Sources/ClaudeCodeBuddy/Marketplace/marketplace.json"

# 插件源目录（默认本仓 plugins/；BUDDY_LOCAL_PLUGINS_DIR 保留 override 便于实验性目录测试）
SOURCE_DIR="${BUDDY_LOCAL_PLUGINS_DIR:-$REPO_ROOT/plugins}"

# FETCH_MARKER（写一个标记文件记录成功 fetch 的 commit，便于排查）
FETCH_MARKER="$PLUGINS_DIR/.fetched-from"

# MARK: - helper

log() { echo "[fetch-plugins] $*" >&2; }
warn() { echo "[fetch-plugins] WARN: $*" >&2; }
err() { echo "[fetch-plugins] ERROR: $*" >&2; }

# 生成 bundle marketplace.json（gitSubdir → localSubdir 改写）
# 参数：$1 = 仓内 marketplace.json 源路径
generate_bundle_marketplace() {
    local src="$1"
    # 用 python3 改写：保留顶层字段，遍历 plugins[]，把对象型 source 改成 "./plugins/<name>" 字符串
    /usr/bin/python3 - "$src" "$MARKETPLACE_JSON" <<'PYEOF'
import json, sys

src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as f:
    manifest = json.load(f)

for plugin in manifest.get("plugins", []):
    name = plugin.get("name", "")
    # gitSubdir/gitURL/file 统一改写为 localSubdir（bundle 内文件已 rsync 就位）
    plugin["source"] = "./plugins/" + name

with open(dst_path, "w") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF
}

# MARK: - main

# 兜底：若 PLUGINS_DIR 已有内容（之前 fetch 过），允许跳过（开发离线场景）
# 用 SKIP_FETCH_PLUGINS=1 显式跳过（仅本地调试）。
if [ "${SKIP_FETCH_PLUGINS:-0}" = "1" ]; then
    warn "SKIP_FETCH_PLUGINS=1，跳过 fetch（保留现有 plugins/ 内容）"
    exit 0
fi

if [ ! -d "$SOURCE_DIR" ]; then
    err "插件源目录不存在: $SOURCE_DIR"
    err "  官方插件已收编进本仓 plugins/；如需 override 请设 BUDDY_LOCAL_PLUGINS_DIR=<path>"
    exit 1
fi
if [ ! -f "$SOURCE_DIR/marketplace.json" ]; then
    err "插件源缺少 marketplace.json: $SOURCE_DIR/marketplace.json"
    exit 1
fi

# rsync 插件内容覆盖填充（--delete 语义由先清后拷实现，保留占位文件）
mkdir -p "$PLUGINS_DIR"
# 先清空 plugins/ 下的旧插件目录（保留占位文件），避免删除插件后残留
find "$PLUGINS_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.gitignore' ! -name '.gitkeep' ! -name '.fetched-from' \
    -exec rm -rf {} +
# rsync 插件内容（源=本仓 plugins/ 仓根，排除非插件文件：
# .git* 与 README.md 是仓级元数据；marketplace.json 走 generate_bundle_marketplace 单独改写，
# 不随目录进 bundle plugins/，也防止覆盖嵌套 .gitignore（Marketplace/plugins 构建产物忽略规则））
rsync -a --exclude='.git' --exclude='.gitignore' --exclude='.gitattributes' \
    --exclude='README.md' --exclude='marketplace.json' \
    "$SOURCE_DIR/" "$PLUGINS_DIR/"

# 生成 bundle marketplace.json（gitSubdir → localSubdir 改写）
generate_bundle_marketplace "$SOURCE_DIR/marketplace.json"

# 记录 fetch 来源（排查用；同仓源直接读本仓 HEAD commit）
commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "in-repo@${commit}" > "$FETCH_MARKER"

log "fetch 成功（in-repo ${commit:0:12}，源: ${SOURCE_DIR}）"
