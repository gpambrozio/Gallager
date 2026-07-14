import ArgumentParser
import Foundation

struct ListSessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-sessions",
        abstract: "List all tmux sessions"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.list", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(sessions) = result["sessions"] {
            for session in sessions {
                if
                    case let .object(obj) = session,
                    case let .string(name) = obj["name"],
                    case let .int(windowCount) = obj["window_count"] {
                    let attached = obj["is_attached"]?.boolValue == true ? " (attached)" : ""
                    print("\(name)\t\(windowCount) windows\(attached)")
                }
            }
        }
    }
}

struct NewSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-session",
        abstract: "Create a new session"
    )

    @Option(name: .long, help: "Session name")
    var name: String?

    @Option(name: .long, help: "Working directory for the new session (defaults to $HOME)")
    var path: String?

    @Option(name: .long, help: "Custom title to display for the session in the sidebar")
    var title: String?

    @Option(
        name: .long,
        help: "Sidebar color: red, orange, yellow, green, blue, purple, pink, gray"
    )
    var color: String?

    @Flag(
        name: .long,
        help: "If a session with --name already exists, return its info instead of creating a new one"
    )
    var ifMissing = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        if ifMissing, name == nil {
            throw ValidationError("--if-missing requires --name to know what to look for")
        }
        var params: [String: JSONValue] = [:]
        if let name { params["name"] = .string(name) }
        if let path { params["path"] = .string(path) }
        if let title { params["title"] = .string(title) }
        if let color { params["color"] = .string(color) }
        if ifMissing { params["if_missing"] = .bool(true) }
        let response = try executeRequest(method: "session.create", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            let created = result["created"]?.boolValue ?? true
            print(created ? "Created session: \(id)" : "Session already exists: \(id)")
        }
    }
}

struct SelectSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-session",
        abstract: "Switch to a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.select",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct CurrentSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current-session",
        abstract: "Show active session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.current", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(name) = result["name"] {
            print(name)
        }
    }
}

struct CloseSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-session",
        abstract: "Close a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.close",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct SetTitleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-title",
        abstract: "Set a custom title shown for a session in the sidebar",
        discussion: """
        Titles always apply to a whole session — every window in the session
        renders the same title. Persisted as the tmux user option
        `@gallager-description` so it survives app restarts. Pass an empty
        string to clear the title.

        Targeting:
          --session SESSION  the session to update
          (none)             defaults to the calling pane's session via $TMUX_PANE

        To rename the tab label of a single window, use `gallager rename-window`.
        """
    )

    @Argument(help: "Title text. Pass an empty string (\"\") to clear.")
    var title: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["title": .string(title)]
        if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(
            method: "session.set_title",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print(title.isEmpty ? "Cleared session title." : "Set session title.")
        }
    }
}

private func canonicalColorDisplayName(for raw: String) -> String? {
    switch raw.lowercased() {
    case "red": "Red"
    case "orange": "Orange"
    case "yellow": "Yellow"
    case "green": "Green"
    case "blue": "Blue"
    case "purple",
         "violet": "Purple"
    case "pink",
         "magenta": "Pink"
    case "gray",
         "grey": "Gray"
    default: nil
    }
}

struct SetColorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-color",
        abstract: "Set a custom color shown next to a session in the sidebar",
        discussion: """
        Colors always apply to a whole session — every window in the session
        renders the same dot. Persisted as the tmux user option
        `@gallager-color` so it survives app restarts. Pass an empty string
        or "none" to clear the color.

        Valid colors: red, orange, yellow, green, blue, purple, pink, gray.

        Targeting:
          --session SESSION  the session to update
          (none)             defaults to the calling pane's session via $TMUX_PANE
        """
    )

    @Argument(help: "Color name. Pass an empty string (\"\") or \"none\" to clear.")
    var color: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        // Pass an empty string when the user requested to clear so the API
        // treats it consistently with `set-title`.
        let normalized: String
        if color.lowercased() == "none" || color.isEmpty {
            normalized = ""
        } else {
            normalized = color
        }
        var params: [String: JSONValue] = ["color": .string(normalized)]
        if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(
            method: "session.set_color",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            if normalized.isEmpty {
                print("Cleared session color.")
            } else {
                // Falls back to the raw value when the server accepted a name
                // we don't recognise locally. Aliases (violet → Purple, etc.)
                // are normalized so confirmation matches what the app shows.
                let displayName = canonicalColorDisplayName(for: normalized) ?? normalized
                print("Set session color to \(displayName).")
            }
        }
    }
}

struct SetEmojiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-emoji",
        abstract: "Set a custom emoji icon shown next to a session in the sidebar",
        discussion: """
        Emoji always apply to a whole session — every window in the session
        renders the same icon. Persisted as the tmux user option
        `@gallager-emoji` so it survives app restarts. Pass an empty string
        or "none" to clear the emoji.

        Accepts either:
          • An emoji character directly (e.g. "🚀", "🐛")
          • A name or keyword (e.g. "rocket", "bug", "trash",
            "smiling face with heart-eyes")

        Names match CLDR keyword synonyms too, so "trash" resolves 🗑️ even
        though its Unicode name is WASTEBASKET. When a query matches multiple
        emoji the candidates are listed so you can rerun with a more specific
        one. Use `gallager find-emoji <query>` to browse matches without
        committing.

        Targeting:
          --session SESSION  the session to update
          (none)             defaults to the calling pane's session via $TMUX_PANE
        """
    )

    @Argument(help: "Emoji character or name (e.g. \"🚀\", \"rocket\"). Pass an empty string (\"\") or \"none\" to clear.")
    var emoji: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let resolved = try Self.resolveEmoji(from: emoji)
        var params: [String: JSONValue] = ["emoji": .string(resolved.value)]
        if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(
            method: "session.set_emoji",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            if resolved.value.isEmpty {
                print("Cleared session emoji.")
            } else if let resolvedName = resolved.resolvedName {
                print("Set session emoji to \(resolved.value) (\(resolvedName)).")
            } else {
                print("Set session emoji to \(resolved.value).")
            }
        }
    }

    /// Outcome of parsing the argument: an empty `value` means "clear",
    /// a populated `value` is the string to persist, and `resolvedName` is set
    /// only when we looked up the emoji by name so the confirmation can echo it.
    struct Resolved {
        let value: String
        let resolvedName: String?
    }

    static func resolveEmoji(from input: String) throws -> Resolved {
        if input.isEmpty || input.lowercased() == "none" {
            return Resolved(value: "", resolvedName: nil)
        }
        // Direct emoji input — keep the existing fast path so users who paste
        // the character still get the original behavior. Require every scalar
        // to be emoji-ish (emoji, variation selector, or ZWJ joiner) so a
        // name typo containing one stray emoji like "rocekt 🚀" still falls
        // through to the lookup path instead of being persisted verbatim.
        if isEntirelyEmoji(input) {
            return Resolved(value: input, resolvedName: nil)
        }
        // Fall back to name/description lookup.
        let matches = EmojiNameLookup.search(query: input)
        switch matches.count {
        case 0:
            throw ValidationError(
                "\"\(input)\" doesn't match any emoji. Pass the emoji character itself, an empty string to clear, or try `gallager find-emoji \(input)` to search."
            )
        case 1:
            let match = matches[0]
            return Resolved(value: match.emoji, resolvedName: match.name.lowercased())
        default:
            var message = "\"\(input)\" matches multiple emoji — be more specific:\n"
            let preview = matches.prefix(20)
            for match in preview {
                message += "  \(match.emoji)  \(match.name.lowercased())\n"
            }
            if matches.count > preview.count {
                message += "  …and \(matches.count - preview.count) more (try `gallager find-emoji \(input)`).\n"
            }
            throw ValidationError(message)
        }
    }

    /// True when every scalar in `input` is either an emoji or a glue scalar
    /// (variation selector or ZWJ) used inside emoji sequences — i.e. the
    /// whole string is a sequence of emoji characters with no surrounding
    /// text. Allows multi-scalar emoji (skin tones, ZWJ sequences like
    /// 👨‍🚀, flags, ❤️) through the fast path while routing anything mixed
    /// with prose ("rocket 🚀", "fire fox") to the name lookup.
    private static func isEntirelyEmoji(_ input: String) -> Bool {
        guard !input.isEmpty else { return false }
        return input.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isEmoji
                || scalar.properties.isVariationSelector
                || scalar == "\u{200D}"
        }
    }
}

struct FindEmojiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-emoji",
        abstract: "Search for emoji by name or keyword",
        discussion: """
        Looks up emoji by their display name or CLDR keyword synonyms, so common
        words work even when they aren't the formal Unicode name — e.g. "trash"
        finds 🗑️ (named WASTEBASKET). Every whitespace-separated word in the
        query must appear in the candidate's name or keywords (case-insensitive).

        Examples:
          gallager find-emoji rocket
          gallager find-emoji trash
          gallager find-emoji "smiling face"
          gallager find-emoji heart
        """
    )

    @Argument(help: "Search query (e.g. \"rocket\", \"smiling face\").")
    var query: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        let matches = EmojiNameLookup.search(query: query)
        if matches.isEmpty {
            if json {
                // Scripted callers (`gallager find-emoji foo --json | jq ...`)
                // treat an empty array as "success, but no results", so emit
                // `[]` on stdout and exit 0. Interactive callers still get a
                // non-zero exit + stderr message so shell scripts can branch
                // on `if gallager find-emoji foo > /dev/null; then …`.
                print("[]")
                return
            }
            FileHandle.standardError.write(
                Data("No emoji matches \"\(query)\".\n".utf8)
            )
            throw ExitCode.failure
        }
        if json {
            let payload = matches.map { match in
                ["emoji": match.emoji, "name": match.name.lowercased()]
            }
            if
                let data = try? JSONEncoder().encode(payload),
                let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            for match in matches {
                print("\(match.emoji)  \(match.name.lowercased())")
            }
        }
    }
}

struct SessionStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-state",
        abstract: "Override the displayed state of a tmux session in the sidebar",
        discussion: """
        Sets a synthetic state on the session's pane (or every pane in a target
        session). The override stays in place until cleared explicitly or until
        a Claude hook event for the same pane changes the underlying state.

        States: working, idle, waiting, clear
        Aliases: "waiting-for-input", "attention" (waiting); "none" (clear).
        """
    )

    @Argument(help: "State to apply: working, idle, waiting, or clear")
    var state: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["state": .string(state)]
        if let pane = options.pane {
            params["pane_id"] = .string(pane)
        } else if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(
            method: "session.set_state",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .int(applied) = result["applied_to"] {
            let canonical = Self.canonicalState(for: state)
            if applied == 0 {
                print("No matching panes found.")
            } else if canonical == "clear" {
                print("Cleared state on \(applied) pane(s).")
            } else {
                print("Set state '\(canonical)' on \(applied) pane(s).")
            }
        }
    }

    /// Maps the user-supplied state argument (and supported aliases) to the
    /// canonical name used in the sidebar so the success message stays in sync
    /// regardless of which alias or casing the caller typed.
    private static func canonicalState(for raw: String) -> String {
        switch raw.lowercased() {
        case "clear",
             "none":
            return "clear"
        case "working":
            return "working"
        case "idle":
            return "idle"
        case "waiting",
             "waiting-for-input",
             "attention":
            return "waiting"
        default:
            return raw.lowercased()
        }
    }
}
