#if os(macOS)
    import Foundation

    /// Expands `${VAR}` and `$VAR` references in layout strings.
    ///
    /// Supports `${VAR:-default}` for inline defaults. Backslash before `$`
    /// (`\$`) escapes a literal dollar. No command substitution, arithmetic,
    /// or globbing — those remain out of scope per the apply spec.
    public struct LayoutVariableExpander: Sendable {
        /// One occurrence of an undefined variable encountered while expanding.
        /// Surfaces through the parser as a stderr warning under `--lenient` or
        /// as a validation error in strict mode.
        public struct UndefinedReference: Sendable, Equatable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        public let environment: [String: String]

        public init(environment: [String: String]) {
            self.environment = environment
        }

        /// Expands every `$VAR` / `${VAR}` reference in `input`. Records any
        /// undefined references in `undefined` so the caller can decide how
        /// loudly to react.
        public func expand(_ input: String, undefined: inout [UndefinedReference]) -> String {
            var result = ""
            result.reserveCapacity(input.count)
            let chars = Array(input)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                    // \$ escapes the dollar — drop the backslash, keep the $.
                    result.append("$")
                    i += 2
                    continue
                }
                guard c == "$" else {
                    result.append(c)
                    i += 1
                    continue
                }
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    // ${VAR} or ${VAR:-default}
                    var j = i + 2
                    while j < chars.count, chars[j] != "}" {
                        j += 1
                    }
                    if j >= chars.count {
                        // Unterminated — emit literally so the user sees it in
                        // the surfaced error rather than silently swallowing.
                        result.append(contentsOf: chars[i..<chars.count])
                        i = chars.count
                        continue
                    }
                    let body = String(chars[(i + 2)..<j])
                    let (name, defaultValue) = Self.parseBracedExpansion(body)
                    // POSIX-aligned: `${VAR:-default}` treats an unset *or
                    // empty* value as missing. Bare `${VAR}` keeps an empty
                    // string as a valid expansion — the value is defined,
                    // it just happens to be empty, so it's not undefined.
                    if let defaultValue {
                        if let value = environment[name], !value.isEmpty {
                            result.append(value)
                        } else {
                            result.append(defaultValue)
                        }
                    } else if let value = environment[name] {
                        result.append(value)
                    } else {
                        undefined.append(UndefinedReference(name: name))
                    }
                    i = j + 1
                    continue
                }
                // $VAR — alphanumeric + underscore.
                var j = i + 1
                while j < chars.count, Self.isVarNameChar(chars[j], first: j == i + 1) {
                    j += 1
                }
                if j == i + 1 {
                    // Lone "$" with no following name — keep literal.
                    result.append("$")
                    i += 1
                    continue
                }
                let name = String(chars[(i + 1)..<j])
                if let value = environment[name] {
                    result.append(value)
                } else {
                    undefined.append(UndefinedReference(name: name))
                }
                i = j
            }
            return result
        }

        private static func parseBracedExpansion(_ body: String) -> (name: String, defaultValue: String?) {
            // Support `${VAR:-default}` only; other shell forms (`:?`, `:+`) are
            // out of scope per spec §7.1.
            if let range = body.range(of: ":-") {
                let name = String(body[..<range.lowerBound])
                let defaultValue = String(body[range.upperBound...])
                return (name, defaultValue)
            }
            return (body, nil)
        }

        private static func isVarNameChar(_ c: Character, first: Bool) -> Bool {
            if c == "_" { return true }
            if first { return c.isLetter }
            return c.isLetter || c.isNumber
        }
    }
#endif
