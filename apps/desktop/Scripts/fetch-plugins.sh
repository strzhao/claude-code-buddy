#!/bin/bash
# fetch-plugins.sh — build-time 从官方插件 monorepo 拉取插件源打进 app bundle（C1/C2/C3/C8）。
#
# 数据流：
#   1. git clone --depth 1 <officialPluginsRepoURL> → temp（含 .git，支持 file:// 与 https://）
#   2. rsync temp/plugins/ → Sources/ClaudeCodeBuddy/Marketplace/plugins/（覆盖填充）
#   3. 读 monorepo marketplace.json，把 gitSubdir source 改写为 localSubdir（./plugins/<name>），
#      生成 bundle 专用 marketplace.json（离线 seed 用，C3 双轨）
#   4. 清理 temp
#   5. 缓存兜底（C8）：clone 失败时若 .cache/buddy-plugins/ 有上次成功 fetch → 用缓存 + stderr 警告；
#      无缓存无网络 → 清晰错误退出非 0（不产半成品）
#
# 时序（C12）：Makefile 链式 fetch-plugins → build-qr-gen → fix-plugin-perms → build/bundle。
# 本脚本由 Makefile `fetch-plugins` target 调用，在 swift build 前执行。
set -euo pipefail

# MARK: - 路径常量

# app 仓库根（Scripts/ 的上两级 = apps/desktop的上两级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$DESKTOP_DIR/Sources/ClaudeCodeBuddy/Marketplace/plugins"
MARKETPLACE_JSON="$DESKTOP_DIR/Sources/ClaudeCodeBuddy/Marketplace/marketplace.json"

# monorepo URL（支持 env 覆盖，便于本地 file:// 测试 + CI 用默认 GitHub）
MONOREPO_URL="${BUDDY_OFFICIAL_PLUGINS_URL:-https://github.com/strzhao/buddy-official-plugins.git}"
MONOREPO_REF="${BUDDY_OFFICIAL_PLUGINS_REF:-main}"

# 缓存目录（C8 兜底）
CACHE_DIR="$DESKTOP_DIR/.cache/buddy-plugins"

# FETCH_MARKER（写一个标记文件记录成功 fetch 的 commit，便于排查）
FETCH_MARKER="$PLUGINS_DIR/.fetched-from"

# MARK: - helper

log() { echo "[fetch-plugins] $*" >&2; }
warn() { echo "[fetch-plugins] WARN: $*" >&2; }
err() { echo "[fetch-plugins] ERROR: $*" >&2; }

# 生成 bundle marketplace.json（gitSubdir → localSubdir 改写）
# 参数：$1 = monorepo marketplace.json 源路径
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

# 应用一次 fetch（clone + rsync + 生成 marketplace.json）
# 参数：$1 = monorepo URL，$2 = ref
do_fetch() {
    local url="$1"
    local ref="$2"
    local tmp
    tmp="$(mktemp -d -t buddy-plugins-fetch)"
    log "git clone --depth 1 --branch $ref $url → $tmp"
    # --branch 接受 branch/tag name；git 2.11+ 支持 shallow clone --branch tag
    if ! git clone --depth 1 --branch "$ref" "$url" "$tmp"; then
        # ref 可能是 commit（--branch 不支持 commit），退回无 --branch 的浅克隆
        log "clone with --branch $ref failed, retry without --branch"
        if ! git clone --depth 1 "$url" "$tmp"; then
            rm -rf "$tmp"
            return 1
        fi
    fi

    # rsync plugins/ 覆盖填充（--delete 保持与 monorepo 一致，但保留 .gitkeep/.gitignore/.fetched-from）
    mkdir -p "$PLUGINS_DIR"
    # 先清空 plugins/ 下的旧插件目录（保留占位文件），避免删除插件后残留
    find "$PLUGINS_DIR" -mindepth 1 -maxdepth 1 \
        ! -name '.gitignore' ! -name '.gitkeep' ! -name '.fetched-from' \
        -exec rm -rf {} +
    # rsync monorepo plugins/ 内容（不含 .git）
    rsync -a --exclude='.git' "$tmp/plugins/" "$PLUGINS_DIR/"

    # 生成 bundle marketplace.json（gitSubdir → localSubdir 改写）
    if [ -f "$tmp/marketplace.json" ]; then
        generate_bundle_marketplace "$tmp/marketplace.json"
    else
        warn "monorepo 无 marketplace.json，保留现有 bundle marketplace.json"
    fi

    # 记录 fetch 来源 commit（排查用）
    local commit="${url:+}"
    commit="$(git -C "$tmp" rev-parse HEAD 2>/dev/null || true)"
    commit="${commit:-unknown}"
    echo "${url}@${ref}@${commit}" > "$FETCH_MARKER"

    # 更新缓存（C8 兜底用）
    mkdir -p "$CACHE_DIR"
    rm -rf "$CACHE_DIR/plugins" "$CACHE_DIR/marketplace.json"
    cp -a "$tmp/plugins" "$CACHE_DIR/plugins"
    cp "$tmp/marketplace.json" "$CACHE_DIR/marketplace.json" 2>/dev/null || true
    echo "${url}@${ref}@${commit}" > "$CACHE_DIR/.fetched-from"

    rm -rf "$tmp"
    log "fetch 成功（${commit}）"
    return 0
}

# 从缓存恢复（C8 兜底）
restore_from_cache() {
    if [ ! -d "${CACHE_DIR}/plugins" ] || [ ! -f "${CACHE_DIR}/marketplace.json" ]; then
        return 1
    fi
    local cached_from="unknown"
    if [ -f "${CACHE_DIR}/.fetched-from" ]; then
        cached_from="$(cat "${CACHE_DIR}/.fetched-from" 2>/dev/null || echo unknown)"
    fi
    warn "fetch 失败，使用缓存 ${CACHE_DIR}（${cached_from}）"
    mkdir -p "$PLUGINS_DIR"
    find "$PLUGINS_DIR" -mindepth 1 -maxdepth 1 \
        ! -name '.gitignore' ! -name '.gitkeep' ! -name '.fetched-from' \
        -exec rm -rf {} +
    rsync -a --exclude='.git' "${CACHE_DIR}/plugins/" "$PLUGINS_DIR/"
    generate_bundle_marketplace "${CACHE_DIR}/marketplace.json"
    echo "cache@${cached_from}" > "$FETCH_MARKER"
    return 0
}

# MARK: - main

# 兜底：若 PLUGINS_DIR 已有内容（之前 fetch 过或本地手写），允许跳过网络（开发离线场景）
# 但 CI/首次构建必须 fetch。用 SKIP_FETCH_PLUGINS=1 显式跳过（仅本地调试）。
if [ "${SKIP_FETCH_PLUGINS:-0}" = "1" ]; then
    warn "SKIP_FETCH_PLUGINS=1，跳过 fetch（保留现有 plugins/ 内容）"
    exit 0
fi

if do_fetch "$MONOREPO_URL" "$MONOREPO_REF"; then
    exit 0
fi

# fetch 失败 → 尝试缓存兜底（C8）
if restore_from_cache; then
    exit 0
fi

# 无缓存无网络 → 清晰错误退出非 0（C8：不产半成品）
err "无法 fetch 官方插件 (网络不可达且无缓存)"
err "  monorepo: ${MONOREPO_URL}"
err "  缓存目录: ${CACHE_DIR} (不存在)"
err ""
err "排查:"
err "  1. 检查网络 (curl -sI ${MONOREPO_URL})"
err "  2. 本地开发可 SKIP_FETCH_PLUGINS=1 跳过 (需已有 plugins/ 内容)"
err "  3. 或设 BUDDY_OFFICIAL_PLUGINS_URL=file:///path/to/buddy-official-plugins 用本地 monorepo"
exit 1
