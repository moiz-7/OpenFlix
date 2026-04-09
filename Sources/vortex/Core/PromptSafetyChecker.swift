import Foundation

/// Lightweight heuristic prompt safety checker. Runs locally, no API calls.
struct PromptSafetyChecker {

    enum SafetyLevel: String, Codable {
        case safe, warning, blocked
    }

    struct CheckResult: Codable {
        let level: SafetyLevel
        let flags: [String]
        let sanitized: String?
    }

    // MARK: - Blocked patterns (immediate rejection)

    private static let blockedPatterns: [(category: String, keywords: [String])] = [
        ("csam", ["child abuse", "child exploitation", "underage", "minor explicit"]),
        ("extreme_violence", ["gore video", "snuff film", "torture video", "execution video"]),
        ("pii_generation", ["social security number", "credit card number", "generate ssn", "generate credit card"]),
        ("malware", ["ransomware tutorial", "how to hack", "exploit code"]),
    ]

    // MARK: - Warning patterns (flagged but not blocked)

    private static let warningPatterns: [(category: String, keywords: [String])] = [
        ("violence", ["violence", "fighting", "blood", "weapon", "gun", "knife attack"]),
        ("suggestive", ["nude", "naked", "explicit", "nsfw", "sexual"]),
        ("deceptive", ["deepfake", "impersonate", "fake news"]),
    ]

    /// Check a prompt for safety concerns.
    static func check(_ prompt: String) -> CheckResult {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty/whitespace-only prompts are safe (will fail at provider level)
        guard !lower.isEmpty else {
            return CheckResult(level: .safe, flags: [], sanitized: nil)
        }

        var blockedFlags: [String] = []
        var warningFlags: [String] = []

        // Check blocked patterns
        for (category, keywords) in blockedPatterns {
            for keyword in keywords {
                if lower.contains(keyword) {
                    blockedFlags.append(category)
                    break
                }
            }
        }

        if !blockedFlags.isEmpty {
            return CheckResult(level: .blocked, flags: blockedFlags, sanitized: nil)
        }

        // Check warning patterns
        for (category, keywords) in warningPatterns {
            for keyword in keywords {
                if lower.contains(keyword) {
                    warningFlags.append(category)
                    break
                }
            }
        }

        if !warningFlags.isEmpty {
            return CheckResult(level: .warning, flags: warningFlags, sanitized: prompt)
        }

        return CheckResult(level: .safe, flags: [], sanitized: nil)
    }
}
