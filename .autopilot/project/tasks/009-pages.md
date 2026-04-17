---
id: "009-pages"
depends_on: ["006-api-skins", "007-api-upload", "008-api-admin"]
---

# 009: H5 上传页 + Admin 审核仪表盘

## 目标

创建两个页面：移动端友好的皮肤包上传页和管理员审核仪表盘。

## /upload 页面

### 功能

- 文件选择器 (accept=".zip")
- 作者名输入框
- 提交按钮
- 客户端文件大小检查 (>5MB 立即提示)
- 上传进度指示器 (indeterminate spinner)
- 成功: 绿色提示 "已提交，等待管理员审核"
- 失败: 红色错误列表 (显示校验错误)

### 组件

- `src/app/upload/page.tsx` — 服务端包装
- `src/components/UploadForm.tsx` — "use client" 客户端组件

### 设计要求

- 移动端优先响应式布局
- Tailwind CSS 样式
- 表单 POST 到 `/api/upload` (multipart/form-data)

## /admin 页面

### 功能

- Tab 栏: Pending / Approved / Rejected / All
- 每个 tab 调用 `GET /api/admin/skins?status=...`
- 皮肤卡片显示: name, author, version, canvas_size, animation count, preview image
- 可折叠 manifest JSON 查看器 (`<details>` 标签)
- Pending tab: Approve (绿色) + Reject (红色，弹出 reason 输入) 按钮
- Approved/Rejected tab: Delete 按钮
- 操作后自动刷新列表

### 组件

- `src/app/admin/page.tsx` — 服务端包装
- `src/components/AdminDashboard.tsx` — "use client" 主组件
- `src/components/SkinCard.tsx` — 共享皮肤卡片
- `src/components/StatusBadge.tsx` — 状态徽章

## 验收标准

- [ ] /upload 页面可选择 zip 文件并上传
- [ ] 上传成功显示成功提示
- [ ] 上传失败显示具体错误
- [ ] /admin 页面 tab 切换正常
- [ ] approve/reject/delete 操作生效
- [ ] 移动端布局适配
- [ ] `npm run build` 通过
