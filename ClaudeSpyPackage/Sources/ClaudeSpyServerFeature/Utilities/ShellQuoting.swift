import Foundation

extension String {
    /// POSIX single-quote this string for safe substitution into a shell
    /// command (`/bin/sh -c` arguments, text typed into panes, suggested rc
    /// lines). Wraps the value in single quotes and escapes embedded single
    /// quotes via the `'\''` idiom. Also valid for fish for quote-free values
    /// (the only realistic case for an editor path).
    var posixSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
