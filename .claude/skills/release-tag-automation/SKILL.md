---
name: release-tag-automation
description: Automate the full release pipeline for claude-code-buddy — bump version, create tag, push, poll GitHub Actions CI/CD, and brew upgrade. Use when the user says "发布新版本", "release", "打 tag", "发布", "升级版本", or wants to ship a new version of the app.
---

# Release Tag Automation

自动化 claude-code-buddy macOS 应用的完整发布链路：版本号升级 → 打 tag 推送 → 等待 GitHub Actions CI/CD → brew upgrade 本地升级。

## 前置条件

- `gh` CLI 已安装并认证为 `strzhao`
- `brew` 已安装，已 tap `strzhao/claude-code-buddy`
- `jq` 已安装
- 当前目录为仓库根目录，工作区干净（无未提交变更）
- `git remote origin` 指向 `strzhao/claude-code-buddy`

## 发布流程

按顺序执行以下步骤，任何步骤失败立即停止并报告原因。

### 1. 检查前置条件

验证工作区状态、工具可用性、gh 认证状态：

```bash
git diff --quiet && git diff --cached --quiet || { echo "工作区不干净，请先提交或 stash 变更"; exit 1; }
gh auth status
```

### 2. 确定当前版本号和下一个版本号

当前版本号从 `homebrew/Casks/claude-code-buddy.rb` 中读取（单一真相源）：

```bash
CURRENT_VERSION=$(grep -o 'version "[^"]*"' homebrew/Casks/claude-code-buddy.rb | head -1 | sed 's/version "\(.*\)"/\1/')
```

版本号遵循 `MAJOR.MINOR.PATCH` 格式。默认执行 patch 升级（`PATCH + 1`）：

```bash
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
NEXT_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
```

如果用户显式指定了 major 或 minor 升级，则相应增加并归零后续位。

向用户展示：
```
当前版本: vCURRENT_VERSION
下一个版本: vNEXT_VERSION
```

确认后再继续。

### 3. 更新版本号文件

需要更新两个文件中的版本号：

**a) `apps/desktop/Sources/ClaudeCodeBuddy/Resources/Info.plist`**
```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" apps/desktop/Sources/ClaudeCodeBuddy/Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_VERSION" apps/desktop/Sources/ClaudeCodeBuddy/Resources/Info.plist
```

**b) `homebrew/Casks/claude-code-buddy.rb`**（只更新 version；sha256 由 CI 在 release 构建完成后自动填充）
```bash
sed -i '' "s/version \".*\"/version \"$NEXT_VERSION\"/" homebrew/Casks/claude-code-buddy.rb
```

> **为什么只更新 version 不更新 sha256**：sha256 需要从实际的 release zip 计算，而这个 zip 要等 GitHub Actions 构建完成后才存在。CI workflow 中的 `update-homebrew-tap` job 会自动下载 zip、计算 sha256、更新 cask 并推送到 tap 仓库。

### 4. 提交版本变更并打 tag

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Resources/Info.plist homebrew/Casks/claude-code-buddy.rb
git commit -m "chore(release): version $NEXT_VERSION → v$NEXT_VERSION"
git tag "v$NEXT_VERSION"
```

### 5. 推送 tag 和提交

```bash
git push origin main
git push origin "v$NEXT_VERSION"
```

推送 tag 会触发 GitHub Actions 上的 `release.yml` workflow（`on.push.tags: v*.*.*`）。

### 6. 等待 GitHub Actions CI/CD 完成

使用 `gh` CLI 轮询 workflow run 状态。release workflow 有两个 job：
- `release`（"Build + Release (universal)"）— 在 `macos-14` 单机上 native 编译 arm64 + 交叉编译 x86_64，lipo 合并 universal binary、组装 .app、ad-hoc 签名、zip、创建 GitHub Release
- `update-homebrew-tap`（"Update Homebrew Tap"）— 在 `ubuntu-latest` 上下载 release zip 算 sha256、更新 Cask formula、推送到 tap 仓库、并把 cask 同步回 main

**获取 workflow run ID**：

```bash
gh run list --workflow release.yml --branch "v$NEXT_VERSION" --limit 1 --json databaseId --jq '.[0].databaseId'
```

如果 workflow 尚未开始（返回空），等待 10 秒后重试，最多重试 30 次。

**轮询状态**：

```bash
gh run watch <RUN_ID> --exit-status
```

或者手动轮询以提供更详细的状态反馈：

```bash
while true; do
  STATUS=$(gh run view <RUN_ID> --json status,conclusion --jq '[.status, .conclusion] | @tsv')
  # STATUS 格式: "completed\tfailure" 或 "in_progress\t"
  # 向用户展示当前状态
  # 如果 status 为 completed，检查 conclusion：
  #   - success → 继续下一步
  #   - failure → 报告失败并停止
  #   - cancelled → 报告取消并停止
  sleep 30
done
```

> **预计等待时间**：约 2-5 分钟（实测 v0.37.8：release job ~1m54s，update-homebrew-tap ~5s，合计约 2 分钟；随 runner 负载浮动）。向用户展示当前进度。

### 7. 等待 Homebrew tap 仓库同步

CI 的 `update-homebrew-tap` job 会将更新的 cask 推送到 `strzhao/homebrew-claude-code-buddy` 仓库。为确保 `brew upgrade` 拿到最新版本，等待 30 秒让 git 同步完成。

### 8. 更新本地 tap 并 brew upgrade

> **关键**：`brew tap --force` 不会更新已存在的本地 tap clone。必须先 `git pull` 更新本地 tap 仓库，否则 `brew upgrade` 可能安装旧版本。

```bash
# 更新本地 tap clone（brew tap --force 不够，必须 git pull）
# 注意：必须用 brew --repository，不能用 brew --prefix。
#   - Apple Silicon: brew --prefix=/opt/homebrew，brew --repository=/opt/homebrew，tap 在 /opt/homebrew/Library/Taps/
#   - Intel:         brew --prefix=/usr/local，  brew --repository=/usr/local/Homebrew，tap 在 /usr/local/Homebrew/Library/Taps/
# 旧写法 $(brew --prefix)/Homebrew/Library/Taps/ 在 Apple Silicon 上拼成 /opt/homebrew/Homebrew/Library/Taps/（多一段 Homebrew/）会找不到。
TAP_DIR="$(brew --repository)/Library/Taps/strzhao/homebrew-claude-code-buddy"
git -C "$TAP_DIR" pull origin main

# 确认 tap cask 版本正确
grep 'version "' "$TAP_DIR/Casks/claude-code-buddy.rb"

# 升级
brew upgrade claude-code-buddy
```

验证升级后的版本：

```bash
brew info claude-code-buddy --cask | head -5
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/ClaudeCodeBuddy.app/Contents/Info.plist
```

### 9. 报告完成

向用户报告发布结果：

```
✅ 发布完成！
   版本: vNEXT_VERSION
   GitHub Release: https://github.com/strzhao/claude-code-buddy/releases/tag/vNEXT_VERSION
   本地已升级到 vNEXT_VERSION
```

## 错误处理

| 场景 | 处理方式 |
|------|---------|
| 工作区不干净 | 提示用户先提交或 stash |
| gh 未认证 | 提示运行 `gh auth login` |
| 版本号格式异常 | 显示读取到的版本号，让用户手动指定 |
| CI workflow 失败 | 显示 workflow URL，让用户检查日志 |
| CI workflow 超时（>10 分钟） | 提示用户手动检查 |
| brew upgrade 装旧版本 | `brew tap --force` 不会更新本地 tap clone，需要 `git -C <tap_dir> pull origin main` |
| depends_on macos 废弃警告 | 将 `depends_on macos: ">= :sonoma"` 改为 `depends_on macos: :sonoma` |

## 使用示例

**默认 patch 升级**：
```
/release-tag-automation
```
自动从 `0.34.0` 升级到 `0.35.0`。

**指定版本**（未来扩展）：
```
/release-tag-automation --version 0.36.0
```
