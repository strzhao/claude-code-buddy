<!-- tags: macos, app-launcher, nsworkspace, cfbundlename, cfbundleidentifier, cfbundledisplayname, info-plist, fuzzy-search, chinese-app, localized-name, alias, launcher, builtin-plugin, wechat, bilibili -->

# macOS app 搜索：必须索引 CFBundleName/CFBundleIdentifier 别名，文件名 ≠ 用户搜索名

## 现象
launcher 的 app 搜索对中文名 app 搜英文名一个都搜不到：搜 `wechat` 找不到微信、搜 `bilibili` 找不到哔哩哔哩。

## 根因
`.app` bundle 的**磁盘文件名**（`url.deletingPathExtension().lastPathComponent`）对中文区 app 常是中文（`/Applications/微信.app`、`/Applications/哔哩哔哩.app`）。索引只存文件名 → 英文 query 与中文 name 做子序列匹配必然 0 分。这**不是**拼音问题——`wechat`/`bilibili` 是 app 自带的真实英文标识，藏在 Info.plist 里：
- 微信：`CFBundleName`/`CFBundleExecutable` = `WeChat`，`CFBundleIdentifier` = `com.tencent.xinWeChat`
- 哔哩哔哩：`CFBundleIdentifier` = `com.bilibili.bilibiliPC`（DisplayName 仍是中文）

## 解决
索引每个 app 时读 `Contents/Info.plist`，把多个字段作为**匹配别名**（display name 仍用文件名，用户可辨识）：
- `CFBundleDisplayName` / `CFBundleName` / `CFBundleExecutable`（拿到 `WeChat`）
- `CFBundleIdentifier` 按 `.` 切分、去掉反域名前缀（`com/org/net/io/co/app/www/cn/us/tv/me`），保留品牌/产品成分（`bilibili`、`bilibiliPC`、`xinWeChat`）

搜索时对一个 entry 的**所有别名取最高分**（`max over aliases of matcher.score(query, alias)`）。读 plist 用 `NSDictionary(contentsOf: Contents/Info.plist)`（比 `Bundle(url:)` 轻、可在后台 Sendable 扫描上下文跑）。

## Lesson
做 macOS app 搜索/启动器，**索引来源必须是 Info.plist 的多字段别名集，而不是 .app 文件名**。文件名在中文/本地化环境下与用户输入的英文品牌名脱节；bundle identifier 是英文品牌名最可靠的兜底来源（连无英文 DisplayName 的 app 也带）。matcher 保持纯字符串函数不变，别名遍历放在 index 层 → 不破坏既有 matcher 契约/测试。
