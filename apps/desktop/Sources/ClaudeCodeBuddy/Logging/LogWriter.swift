import Foundation

/// 日志文件 IO + 轮转 + 保留清理（单职责，从 BuddyLogger 拆出）。
///
/// 契约 C1（轮转/保留/权限）+ C3 容错（任何 IO 失败静默降级，绝不抛出/崩溃/阻塞）+ C3 新鲜度（append 模式）。
///
/// **线程安全**：由 `BuddyLogger` 通过串行 `DispatchQueue` 保护，本类自身不做同步，
/// 所有方法必须在调用方的串行上下文中调用。
final class LogWriter {
    private let queue = DispatchQueue(label: "buddy.logwriter.io")  // 额外兜底串行队列（防御）
    private var fileHandle: FileHandle?
    private var currentSize: Int = 0
    private let logsDir: String
    private let currentPath: String
    private let isoFormatter: ISO8601DateFormatter

    init(logsDir: String = LogConfig.logsDir, currentPath: String = LogConfig.currentLogPath) {
        self.logsDir = logsDir
        self.currentPath = currentPath
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    // MARK: - 初始化（首次启动）

    /// 确保日志目录与当前文件存在（append 模式，跨重启不覆盖）。
    /// 失败静默降级（契约 C3 容错）。
    func ensureCurrentFile() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                atPath: logsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: LogConfig.dirPermissions)]
            )
            // createDirectory 在目录已存在时不会改权限，补一道 chmod 确保契约
            try? fm.setAttributes([.posixPermissions: NSNumber(value: LogConfig.dirPermissions)], ofItemAtPath: logsDir)
        } catch {
            // 目录创建失败：静默降级，写入时会再失败再降级
            return
        }
        if !fm.fileExists(atPath: currentPath) {
            // 新建空文件（权限 0600）
            fm.createFile(atPath: currentPath, contents: nil, attributes: [
                .posixPermissions: NSNumber(value: LogConfig.filePermissions)
            ])
        }
        openHandle()
    }

    private func openHandle() {
        guard fileHandle == nil else { return }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentPath))
            // append 模式：seekToEnd（契约 C3 新鲜度，跨重启追加）
            try handle.seekToEnd()
            currentSize = try Int(handle.offset())
            fileHandle = handle
        } catch {
            fileHandle = nil
            currentSize = 0
        }
    }

    // MARK: - 写入

    /// 编码一行 JSONL 并 append。返回是否实际写入（级别过滤已由调用方完成）。
    func append(level: LogLevel, subsystem: String, msg: String, meta: [String: Any]?) {
        ensureCurrentFileOpen()
        guard let handle = fileHandle else { return }

        let payload: [String: Any] = encodePayload(
            level: level, subsystem: subsystem, msg: msg, meta: meta
        )

        guard let data = encodeLine(payload) else { return }

        // 写前检查轮转（currentSize + data.count > 阈值）
        if currentSize + data.count > LogConfig.rotateSizeBytes {
            rotate(handle: handle)
            // 轮转后 fileHandle 已替换，重新取
            guard let newHandle = fileHandle else { return }
            writeLine(newHandle, data: data)
        } else {
            writeLine(handle, data: data)
        }
    }

    private func ensureCurrentFileOpen() {
        if fileHandle == nil {
            ensureCurrentFile()
        }
    }

    private func encodePayload(level: LogLevel, subsystem: String, msg: String, meta: [String: Any]?) -> [String: Any] {
        var payload: [String: Any] = [
            LogConfig.fieldTimestamp: isoFormatter.string(from: Date()),
            LogConfig.fieldLevel: level.rawValue,
            LogConfig.fieldSubsystem: subsystem,
            LogConfig.fieldMessage: msg
        ]
        if let meta = meta, !meta.isEmpty {
            payload[LogConfig.fieldMeta] = meta
        }
        return payload
    }

    /// JSONSerialization 编码 + 追加 `\n`。失败返回 nil（契约 C3 容错）。
    private func encodeLine(_ payload: [String: Any]) -> Data? {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]   // 稳定字段顺序：level/msg/subsystem/ts（+meta）
            )
            // 追加换行（JSON Lines，UTF-8，每行一个 JSON 对象 + \n）
            guard var line = String(data: data, encoding: .utf8) else { return nil }
            line += "\n"
            return line.data(using: .utf8)
        } catch {
            return nil
        }
    }

    private func writeLine(_ handle: FileHandle, data: Data) {
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()   // 立即落盘（崩溃排查最关键，契约场景 9 之前可见）
            currentSize += data.count
        } catch {
            // 写失败：关闭句柄，下次重试（契约 C3 容错：静默降级）
            closeHandle()
        }
    }

    // MARK: - 轮转（契约 C1）

    /// 当前文件 > 5 MiB → close → rename `buddy-<ts>.jsonl` → reopen 新 `buddy.jsonl`。
    private func rotate(handle: FileHandle) {
        closeHandle()

        let timestamp = archiveTimestamp()
        let archivePath = "\(logsDir)/buddy-\(timestamp).jsonl"
        let fm = FileManager.default

        // rename（永不覆盖：归档命名含时间戳，同秒内多次轮转才可能撞名，用 try? 兜底）
        do {
            try fm.moveItem(atPath: currentPath, toPath: archivePath)
        } catch {
            // move 失败（如目标已存在 / 源不存在）：尝试删除当前文件强制新建
            try? fm.removeItem(atPath: currentPath)
        }

        // 新建当前文件
        fm.createFile(atPath: currentPath, contents: nil, attributes: [
            .posixPermissions: NSNumber(value: LogConfig.filePermissions)
        ])
        openHandle()

        // 轮转后清理超额归档
        pruneArchives()
    }

    /// 归档时间戳 `YYYYMMDD-HHMMSS`。
    private func archiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    // MARK: - 保留清理（契约 C1：目录总占用 > 50 MiB 或归档 > 30 个 → 删除最旧归档）

    func pruneArchives() {
        let fm = FileManager.default
        let archiveURLs: [URL]
        do {
            archiveURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: logsDir), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.lastPathComponent.hasPrefix("buddy-") && $0.pathExtension == "jsonl" }
        } catch {
            return
        }

        guard !archiveURLs.isEmpty else { return }

        // 按修改时间升序（最旧在前）
        var sorted = archiveURLs.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }

        // 计算归档总大小
        func totalSize(_ urls: [URL]) -> Int {
            urls.reduce(0) { acc, url in
                acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        // 删除最旧归档直到满足两个约束：归档数 <= retainMaxArchives 且 总大小 <= retainTotalSizeBytes
        while !sorted.isEmpty &&
                (sorted.count > LogConfig.retainMaxArchives ||
                    totalSize(sorted) > LogConfig.retainTotalSizeBytes) {
            let oldest = sorted.removeFirst()
            try? fm.removeItem(at: oldest)
        }
    }

    // MARK: - 清理句柄

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        currentSize = 0
    }

    /// 关闭句柄（app 退出时调用）。
    func close() {
        closeHandle()
    }

    /// 仅供测试：当前是否已打开文件句柄。
    var hasOpenHandle: Bool { fileHandle != nil }
}
