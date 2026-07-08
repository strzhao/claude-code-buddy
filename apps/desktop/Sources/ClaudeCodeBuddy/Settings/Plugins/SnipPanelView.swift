import SwiftUI
import AppKit

// MARK: - SnipPanelView
//
// snip 片段管理 SwiftUI 视图（GUI CRUD，T2）。
//
// 数据源：SnippetsService.shared（@MainActor 直驱，零进程开销）。
// 操作：List 列表 + 搜索框 + Form 编辑（keyword TextField + content TextEditor）
//       + 占位符语法提示（{date}/{time}/{clipboard}）+ 预览展开
// 删除：调 NSAlert 二次确认（在 SnipPanelVC 处理，避免 SwiftUI .alert 跨 macOS 版本兼容问题）
//
// 契约引用：C1（CRUD API）/ C4（校验）/ AC-SNIPGUI-08/09/11/12/13/17/18/23

struct SnipPanelView: View {

    /// 是否正在编辑（新增/编辑共用同一表单）。
    /// @State（非 @Binding）：editingItem/isCreating 是纯 UI 状态，@State 变化触发 view body
    /// 重新计算 → detailPane 切换 createForm/editForm/previewPane/空态。
    /// 旧实现用 @Binding 桥接 SnipPanelState（ObservableObject），但 view 未 @ObservedObject
    /// 订阅它 → source 变化不触发渲染 → 点「新增片段」无反应（body 不重算，detailPane 停在空态）。
    @State private var editingItem: SnippetItem?
    /// 是否是新增（vs 编辑已有）
    @State private var isCreating: Bool = false
    /// 编辑中 keyword（新增时为输入框，编辑时只读）
    @State private var editKeyword: String = ""
    /// 编辑中 content
    @State private var editContent: String = ""
    /// 字段级错误提示（C4 校验）
    @State private var keywordError: String?
    @State private var contentError: String?
    /// 搜索过滤 query
    @State private var searchQuery: String = ""
    /// 当前选中查看预览的片段（AC-SNIPGUI-23 占位符展开预览）
    @State private var previewItem: SnippetItem?
    /// 触发删除请求（由 SnipPanelVC 弹 NSAlert 处理）
    var onDeleteRequest: ((SnippetItem) -> Void)?

    /// 测试/外部注入初始编辑态（验证 createForm/editForm 渲染；生产路径用默认值）。
    /// 绕开 SwiftUI Button performClick 盲区（SwiftUI Button 不是 NSButton，进程内 click 不触发）。
    init(
        initialEditingItem: SnippetItem? = nil,
        initialIsCreating: Bool = false,
        initialEditContent: String = "",
        onDeleteRequest: ((SnippetItem) -> Void)? = nil
    ) {
        self._editingItem = State(initialValue: initialEditingItem)
        self._isCreating = State(initialValue: initialIsCreating)
        self._editContent = State(initialValue: initialEditContent)
        self.onDeleteRequest = onDeleteRequest
    }

    // imp-SwiftUI 数据流（qa-reviewer High 2 修复）：
    // @ObservedObject 观察 service.items 的 @Published mutation，CRUD（含 SnipPanelVC 删除）后 List 自动刷新。
    // @State 持 reference type 只观察引用本身（永不变），不观察内部 items mutation → 列表不刷新。
    @ObservedObject private var service: SnippetsService = .shared

    var body: some View {
        HSplitView {
            // 左：列表 + 搜索
            listPane
                .frame(minWidth: 220)

            // 右：编辑表单 / 预览
            detailPane
                .frame(minWidth: 320)
        }
        .padding()
        .onChange(of: previewItem) { _, _ in
            // 点列表项 = 切预览。取消编辑/新增态让 detailPane 切到 previewPane
            // （editingItem 非 nil 时 createForm/editForm 优先于 previewPane → 点列表项看似无反应）。
            cancelEdit()
        }
    }

    // MARK: - 列表面板

    private var listPane: some View {
        VStack(spacing: 0) {
            // 搜索框（AC-SNIPGUI-12）
            TextField("搜索 keyword...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .padding(.bottom, 8)

            // 新增按钮
            Button(action: startCreate) {
                Label("新增片段", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.bottom, 8)

            // 片段列表（按 searchQuery 过滤）
            List(filteredItems, id: \.keyword, selection: $previewItem) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.keyword)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(item.content)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .tag(item)
                .contextMenu {
                    Button("编辑") { startEdit(item) }
                    Button("删除") { onDeleteRequest?(item) }
                }
            }
            // 空态占位（AC-SNIPGUI-14）
            .overlay {
                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(searchQuery.isEmpty ? "尚无片段" : "无匹配片段")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 详情面板（编辑表单 / 预览）

    @ViewBuilder
    private var detailPane: some View {
        if editingItem != nil, isCreating {
            createForm
        } else if let item = editingItem, !isCreating {
            editForm(item: item)
        } else if let preview = previewItem {
            previewPane(item: preview)
        } else {
            // 默认空态（提示用户选择/新增）
            VStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("选择片段查看或预览，或点新增")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 新增表单
    //
    // 纯 VStack + 卡片（不用 Form）：SwiftUI macOS Form Section 行默认 labeled-content 布局
    // （label 左 + content 右窄列），把 TextField/TextEditor/VStack 挤到右侧约 1/3 宽度，
    // .frame(maxWidth:.infinity) 和去 .formStyle(.grouped) 都无效（已验证）。
    // 改纯 VStack + 卡片背景（对齐 AppKit SettingsGroupView）彻底避免。

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("新增片段")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("keyword（字母数字_-，1-64）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("输入 keyword", text: $editKeyword)
                        .onChange(of: editKeyword) { _, _ in keywordError = nil }
                    if let err = keywordError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("content").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editContent)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .onChange(of: editContent) { _, _ in contentError = nil }
                    if let err = contentError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()
                placeholderHint.padding(12)
            }
            .background(Color(nsColor: SettingsTheme.cardBackgroundColor))
            .cornerRadius(SettingsTheme.cardCornerRadius)

            HStack {
                Button("取消", role: .cancel) { cancelEdit() }
                Spacer()
                Button("保存") { saveCreate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editKeyword.isEmpty || editContent.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 编辑表单

    private func editForm(item: SnippetItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("编辑片段")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("keyword").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.keyword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(12)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("content").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editContent)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .onChange(of: editContent) { _, _ in contentError = nil }
                    if let err = contentError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()
                placeholderHint.padding(12)

                if let created = item.created_at {
                    Divider()
                    HStack {
                        Text("创建时间").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(created).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if let updated = item.updated_at {
                    Divider()
                    HStack {
                        Text("更新时间").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(updated).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .background(Color(nsColor: SettingsTheme.cardBackgroundColor))
            .cornerRadius(SettingsTheme.cardCornerRadius)

            HStack {
                Button("删除", role: .destructive) { onDeleteRequest?(item) }
                Spacer()
                Button("取消") { cancelEdit() }
                Button("保存") { saveEdit(keyword: item.keyword) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editContent.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 预览面板（AC-SNIPGUI-23 占位符展开）

    private func previewPane(item: SnippetItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预览")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("keyword").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.keyword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(12)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("content（原文）").font(.caption).foregroundStyle(.secondary)
                    Text(item.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("展开后（占位符）").font(.caption).foregroundStyle(.secondary)
                    Text(SnippetsService.expandPlaceholders(item.content))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: SettingsTheme.cardBackgroundColor))
            .cornerRadius(SettingsTheme.cardCornerRadius)

            HStack {
                Button("编辑") { startEdit(item) }
                Spacer()
                Button("删除", role: .destructive) { onDeleteRequest?(item) }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 占位符语法提示（AC-SNIPGUI-13）

    private var placeholderHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("占位符语法", systemImage: "lightbulb")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("{date} → 当前日期 YYYY-MM-DD\n{time} → 当前时间 HH:MM\n{clipboard} → 当前剪贴板内容")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(4)
    }

    // MARK: - 数据 + 操作

    private var filteredItems: [SnippetItem] {
        service.search(searchQuery)
    }

    private func startCreate() {
        editingItem = SnippetItem(keyword: "", content: "")
        isCreating = true
        editKeyword = ""
        editContent = ""
        keywordError = nil
        contentError = nil
    }

    private func startEdit(_ item: SnippetItem) {
        editingItem = item
        isCreating = false
        editKeyword = item.keyword
        editContent = item.content
        keywordError = nil
        contentError = nil
    }

    private func cancelEdit() {
        editingItem = nil
        isCreating = false
        editKeyword = ""
        editContent = ""
        keywordError = nil
        contentError = nil
    }

    private func saveCreate() {
        do {
            try service.add(keyword: editKeyword, content: editContent)
            cancelEdit()
        } catch let err as SnippetsError {
            switch err {
            case .invalidKeyword: keywordError = err.errorDescription
            case .contentTooLong: contentError = err.errorDescription
            case .keywordAlreadyExists: keywordError = err.errorDescription
            case .keywordNotFound: keywordError = err.errorDescription
            }
        } catch {
            keywordError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func saveEdit(keyword: String) {
        do {
            try service.edit(keyword: keyword, content: editContent)
            cancelEdit()
        } catch let err as SnippetsError {
            switch err {
            case .invalidKeyword: keywordError = err.errorDescription
            case .contentTooLong: contentError = err.errorDescription
            case .keywordAlreadyExists: keywordError = err.errorDescription
            case .keywordNotFound: keywordError = err.errorDescription
            }
        } catch {
            contentError = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 占位符展开（AC-SNIPGUI-23，对齐 snippets.sh expand_placeholders）

    // 注：占位符展开逻辑在 SnippetsService.expandPlaceholders(_:)（数据层单一真相源），
    // GUI 预览 + shell 取用读同一展开（C6 一致性）。
}
