# Buddy 官方插件源（plugins/）

官方插件单一真源。2026-09-02 自 strzhao/buddy-official-plugins（已 archive）subtree 收编进
[claude-code-buddy](https://github.com/strzhao/claude-code-buddy) 本仓目录 `plugins/`，
插件仍不编进 app，运行时 fetch/sync 机制不变。

app 编译时通过 `apps/desktop/Scripts/fetch-plugins.sh` 从**本仓** `plugins/` 拷贝所有插件源
经 SPM `.copy("Marketplace")` 打进 `.app` bundle。

## 插件

| 插件 | 目录 | 说明 |
|------|------|------|
| hello | `plugins/hello` | stdin mode 入门示例，回显问候 |
| qr | `plugins/qr` | command mode 二维码生成器（`qr-gen.swift` 源，app 编译期产出 universal binary） |
| qzh | `plugins/qzh` | command mode QzhddrSrv 监控服务开关（候选回调重入） |

## marketplace.json

根目录 `marketplace.json` 对齐 app 的 `MarketplaceManifest` schema：

- 顶层必填 `schemaVersion` / `name` / `owner`
- 每个 plugin 必填 `name` / `description` / `version` / `author` / `source`
- `source` 为 `git-subdir`（`url` + `path` + `ref`，**不填 `sha`** —— 跟随 `main` 最新 commit，
  app 端 `PluginSourceConfig.gitSubdir.sha` 已改为 `String?` 可选）

bundle 内的 `marketplace.json`（app 编译期由 `fetch-plugins.sh` 生成）会把 `git-subdir`
改写为 `localSubdir`（`./plugins/<name>`），供首启离线 seed 用。

## 同步与更新

app 运行时 `MarketplaceManager.syncFromRemote`（1h debounce）从 GitHub Raw 拉取本文件，
检测 `version` 变化后（自动更新开关默认 ON）`git clone` 覆盖 `~/.buddy/launcher-plugins/<name>/`。

## 本地开发

```bash
# 直接改本目录（本仓 plugins/<name>/）→ bump version in marketplace.json + plugins/<name>/plugin.json → commit → push
# app 端生效：cd apps/desktop && make fetch-plugins（同仓拷贝，零网络）
```

app 端 `BUDDY_MARKETPLACE_URL` 环境变量可指向本地 `file://` URL 测试。
