import Foundation

struct TranscriptStats {
    var model: String?
    var totalTokens: Int
}

enum TranscriptReader {
    /// JSONL 路径推导：cwd 中所有非字母数字字符替换为 "-"
    static func transcriptPath(cwd: String, sessionId: String) -> String {
        let encoded = cwd.replacingOccurrences(
            of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression
        )
        return NSHomeDirectory() + "/.claude/projects/" + encoded + "/" + sessionId + ".jsonl"
    }

    /// 读取 JSONL 文件，提取最新 model 和累计 tokens
    static func scan(path: String) -> TranscriptStats {
        var stats = TranscriptStats(model: nil, totalTokens: 0)
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return stats
        }
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (json["type"] as? String) == "assistant",
                  let message = json["message"] as? [String: Any] else {
                continue
            }
            // Model
            if let model = message["model"] as? String {
                stats.model = model
            }
            // Tokens
            if let usage = message["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                stats.totalTokens += input + output + cacheRead + cacheCreate
            }
        }
        return stats
    }

    /// 读取 ~/.claude/sessions/<pid>.json 获取 startedAt
    static func readStartedAt(pid: Int) -> Date? {
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = json["startedAt"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
