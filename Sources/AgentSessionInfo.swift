import Foundation

enum AgentSessionKind: String, Codable, Sendable, Equatable {
    case claude
    case codex
    case antigravity

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .antigravity:
            return "Antigravity"
        }
    }

    var systemImageName: String {
        switch self {
        case .claude:
            return "sparkles"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .antigravity:
            return "paperplane.fill"
        }
    }
}

struct AgentSessionInfo: Codable, Sendable, Equatable {
    var kind: AgentSessionKind
    var sessionId: String?
    var lastCommand: String?
    var detectedTitle: String?
    var workingDirectory: String?
    var updatedAt: TimeInterval

    var restoreCommand: String? {
        guard let sessionId = Self.normalizedSessionId(sessionId) else { return nil }
        switch kind {
        case .claude:
            return "claude --resume \(Self.shellQuoted(sessionId))"
        case .codex:
            return "codex resume \(Self.shellQuoted(sessionId))"
        case .antigravity:
            return nil
        }
    }

    static func detected(
        command: String?,
        title: String?,
        scrollback: String?,
        workingDirectory: String?,
        existing: AgentSessionInfo? = nil,
        now: TimeInterval = Date.now.timeIntervalSince1970
    ) -> AgentSessionInfo? {
        let command = normalized(command)
        let title = normalized(title)
        let scrollback = normalized(scrollback)
        let workingDirectory = normalized(workingDirectory)

        let kind = detectedKind(command: command, title: title, scrollback: scrollback) ?? existing?.kind
        guard let kind else { return nil }

        let sessionId = detectedSessionId(kind: kind, command: command, scrollback: scrollback)
            ?? existing?.sessionId

        return AgentSessionInfo(
            kind: kind,
            sessionId: sessionId,
            lastCommand: command ?? existing?.lastCommand,
            detectedTitle: title ?? existing?.detectedTitle,
            workingDirectory: workingDirectory ?? existing?.workingDirectory,
            updatedAt: now
        )
    }

    private static func detectedKind(command: String?, title: String?, scrollback: String?) -> AgentSessionKind? {
        let commandExecutable = firstCommandToken(command)
        if commandExecutable == "claude" {
            return .claude
        }
        if commandExecutable == "codex" {
            return .codex
        }
        if commandExecutable == "antigravity" {
            return .antigravity
        }

        let searchable = [title, scrollback]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\n")

        if searchable.contains("claude code") || searchable.contains("claude") {
            return .claude
        }
        if searchable.contains("codex") {
            return .codex
        }
        if searchable.contains("antigravity") {
            return .antigravity
        }
        return nil
    }

    private static func detectedSessionId(
        kind: AgentSessionKind,
        command: String?,
        scrollback: String?
    ) -> String? {
        if let commandId = detectedSessionId(kind: kind, text: command, commandMode: true) {
            return commandId
        }
        return detectedSessionId(kind: kind, text: scrollback, commandMode: false)
    }

    private static func detectedSessionId(kind: AgentSessionKind, text: String?, commandMode: Bool) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let tokens = tokenizeShellLike(text)

        switch kind {
        case .claude:
            for (index, token) in tokens.enumerated() {
                if token == "--resume", index + 1 < tokens.count {
                    return normalizedSessionId(tokens[index + 1])
                }
                if token.hasPrefix("--resume=") {
                    return normalizedSessionId(String(token.dropFirst("--resume=".count)))
                }
                if token == "-r", index + 1 < tokens.count {
                    return normalizedSessionId(tokens[index + 1])
                }
            }
        case .codex:
            for (index, token) in tokens.enumerated() where token == "resume" && index + 1 < tokens.count {
                return normalizedSessionId(tokens[index + 1])
            }
        case .antigravity:
            for (index, token) in tokens.enumerated() {
                if token == "--resume", index + 1 < tokens.count {
                    return normalizedSessionId(tokens[index + 1])
                }
                if token.hasPrefix("--resume=") {
                    return normalizedSessionId(String(token.dropFirst("--resume=".count)))
                }
            }
        }

        guard !commandMode else { return nil }
        return firstUUIDLikeToken(in: text)
    }

    private static func firstCommandToken(_ command: String?) -> String? {
        guard let command else { return nil }
        var tokens = tokenizeShellLike(command)
        while let first = tokens.first {
            if first == "env" || first.contains("=") {
                tokens.removeFirst()
                continue
            }
            return URL(fileURLWithPath: first).lastPathComponent.lowercased()
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedSessionId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:()[]{}<>"))
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstUUIDLikeToken(in text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tokenizeShellLike(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

enum AgentSessionRestoreSettings {
    static let autoRestoreKey = "agentSessionAutoRestore"
    static let defaultAutoRestore = true

    static func isAutoRestoreEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: autoRestoreKey) == nil {
            return defaultAutoRestore
        }
        return defaults.bool(forKey: autoRestoreKey)
    }
}
