import Foundation

/// Removes credential material before server errors reach UI, logs, or journals.
public enum CredentialRedactor {
    private static let secretPatterns = [
        #"(?i)(["']?(?:service_account_credentials|token)["']?\s*[:=]\s*")(?:\\.|[^"\\])*""#,
        #"(?s)(-----BEGIN (?:RSA )?PRIVATE KEY-----).*?-----END (?:RSA )?PRIVATE KEY-----"#,
        #"(?i)([\"']?private[_-]?key[\"']?\s*[:=]\s*\")(?:\\.|[^\"\\])*\""#,
        #"(?i)([\"']?authorization[\"']?\s*[:=]\s*[\"']?(?:bearer|basic)\s+)[^\s,;\"}]+"#,
        #"(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|client[_-]?secret|password|RCLONE_RC_PASS)[\"']?\s*[:=]\s*[\"']?)[^\s,;\"'}]+"#
    ]

    public static func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\0", with: "")
        for pattern in secretPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1<redacted>")
        }
        return result
    }
}
