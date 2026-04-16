---
id: "009-skin-store"
depends_on: ["008-settings-ui"]
---

# 009: 远程皮肤商店（目录/下载/缓存/校验）

## 目标
从远程服务器浏览皮肤目录、下载 .zip 皮肤包、解压缓存、校验完整性。

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Skin/SkinPackStore.swift` — 远程目录获取 + 下载 + 解压 + 校验

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Skin/SkinPackManager.swift` — 集成远程目录
- `Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift` — 商店浏览区

## 变更详情

### SkinPackStore
- `RemoteSkinEntry` struct: id, name, author, version, previewURL, downloadURL, size
- `func fetchCatalog(from catalogURL: URL) async throws -> [RemoteSkinEntry]`
  - 下载 JSON 目录文件，解码为 [RemoteSkinEntry]
  - 缓存 1 小时（UserDefaults 时间戳 + 本地 JSON 文件）
- `func downloadSkin(entry: RemoteSkinEntry, progress: @escaping (Double) -> Void) async throws -> SkinPack`
  - URLSession 下载 .zip
  - 报告进度
  - 解压到 `~/Library/Application Support/ClaudeCodeBuddy/Skins/{id}/`
  - **安全校验**: 解压前检查每个 entry path 无 `..` 路径遍历
  - 验证 manifest.json 存在且可解析
  - 验证至少 1 个精灵图存在（spritePrefix-idle-a-1.png）
  - 失败时清理临时文件和残留目录
- `func deleteSkin(id: String) throws`
  - 删除皮肤目录
  - 如果是当前活跃皮肤，降级到 "default"

### SkinPackManager 扩展
- 新增 `func refreshRemoteSkins() async`
- 合并本地和远程皮肤列表

### SkinGalleryViewController 扩展
- 底部 "Store" 区域展示远程可用皮肤
- 每个远程皮肤卡片: 预览图 + 名称 + "Download" 按钮
- 下载中: 进度条替换按钮
- 下载完成: 自动刷新画廊，新皮肤可选

### 线程安全
- 所有 async 方法标记 @MainActor 或在 completion 中 MainActor.run
- URLSession 的 delegate 回调通过 async/await 桥接

## 验收标准
- [ ] `make build` 编译通过
- [ ] 商店区域显示远程皮肤列表（需要可用的 catalog URL）
- [ ] 下载进度条正常显示
- [ ] 下载完成后皮肤立即可选
- [ ] 路径遍历攻击被拒绝
- [ ] 网络中断时显示错误，无残留文件
- [ ] 删除已下载皮肤后如果是活跃皮肤则降级
