import Foundation

public enum AdvancedEnvironmentError: LocalizedError {
    case invalidLine(Int)
    case invalidKey(String, Int)
    case protectedKey(String, Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidLine(line):
            "高级环境变量第 \(line) 行缺少 ="
        case let .invalidKey(key, line):
            "高级环境变量第 \(line) 行的变量名无效：\(key)"
        case let .protectedKey(key, line):
            "第 \(line) 行的 \(key) 请使用上方专用输入框配置"
        }
    }
}

public enum AdvancedEnvironment {
    public static func parse(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw AdvancedEnvironmentError.invalidLine(lineNumber)
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            let keyPattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
            guard key.range(of: keyPattern, options: .regularExpression) != nil else {
                throw AdvancedEnvironmentError.invalidKey(key, lineNumber)
            }
            guard !ClaudeSettingsManager.protectedEnvironmentKeys.contains(key) else {
                throw AdvancedEnvironmentError.protectedKey(key, lineNumber)
            }
            result[key] = value
        }
        return result
    }

    public static func render(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }
}
