import Foundation

/// Generates the shell-startup snippets that keep `$VISUAL` pointing at the
/// in-app `gallager edit` CLI for the lifetime of a mirrored session.
///
/// tmux exports `VISUAL` (and `GALLAGER_SOCKET`) on every session it spawns, but
/// the pane runs a *login* shell, which then sources the user's `~/.zshrc` /
/// `~/.bashrc`. A user who keeps `export VISUAL=<their editor>` in those files
/// clobbers our value, so Ctrl-G in Claude Code / Codex opens their editor
/// instead of the in-app one (issue #589).
///
/// We can't win by setting `VISUAL` *before* the shell starts — the rc files run
/// after and override it. Instead we redirect the shell's startup through a
/// snippet we control, hand control back to the user's real config, and
/// re-assert `VISUAL` *after* every rc file has run:
///
/// - **zsh** — point `ZDOTDIR` at our directory so zsh reads our `.zshenv`
///   first. It captures our `VISUAL`, restores `ZDOTDIR` to the user's real
///   config dir (so `.zprofile`/`.zshrc`/`.zlogin` load untouched), and
///   registers a one-shot `precmd` hook that re-applies `VISUAL` after all rc
///   files have run, just before the first prompt.
/// - **bash** — launch with `--rcfile <our file>` (an interactive, non-login
///   shell), replicate a login shell's startup order ourselves, then re-assert
///   `VISUAL` last.
///
/// `TmuxService.shellLaunchCommand` consumes the paths returned here.
enum ShellIntegration {
    /// Paths to the generated snippets, consumed by `TmuxService`.
    struct Paths {
        /// Directory to hand zsh as `ZDOTDIR` (contains our `.zshenv`).
        let zdotdir: String
        /// File to hand bash via `--rcfile`.
        let bashRC: String
    }

    /// Writes the snippets into `directory` (creating it if needed) and returns
    /// their paths.
    ///
    /// The snippets are static (they read our value from `$VISUAL` at runtime),
    /// so writing them on every launch is idempotent. The directory must stay
    /// alive for the app's whole lifetime — the returned paths are baked into
    /// tmux's `default-command` — so callers pass the durable
    /// `GallagerPaths.shellIntegrationDir`, never a temp dir that macOS may
    /// reap (E2E isolation comes from the `--gallager-state-root` override,
    /// which relocates the whole state tree per instance).
    static func install(into directory: URL) throws -> Paths {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let zshenvURL = directory.appendingPathComponent(".zshenv")
        try zshenv.write(to: zshenvURL, atomically: true, encoding: .utf8)

        let bashRCURL = directory.appendingPathComponent("gallager.bash")
        try bashRC.write(to: bashRCURL, atomically: true, encoding: .utf8)

        return Paths(zdotdir: directory.path, bashRC: bashRCURL.path)
    }

    /// The `.zshenv` placed in our `ZDOTDIR`. Runs before any user rc file.
    static let zshenv = """
    # Gallager shell integration (issue #589) — keep $VISUAL pointing at the
    # in-app `gallager edit` editor even when ~/.zshrc exports its own VISUAL.
    #
    # This file is read because the launcher set ZDOTDIR to the directory that
    # contains it. We capture our VISUAL, hand ZDOTDIR back to the user's real
    # config so their startup files load exactly as usual, and re-apply VISUAL
    # from a one-shot precmd hook that fires after all rc files have run.

    # Our intended VISUAL, captured before any user file can change it.
    typeset -g __gallager_visual="${VISUAL}"

    # Restore ZDOTDIR to the user's real config dir (captured by the launcher,
    # defaulting to $HOME), then source the .zshenv we displaced. Zsh re-reads
    # $ZDOTDIR before each later startup file, so .zprofile/.zshrc/.zlogin now
    # load from the user's dir untouched.
    ZDOTDIR="${GALLAGER_USER_ZDOTDIR:-$HOME}"
    unset GALLAGER_USER_ZDOTDIR
    [[ -r "${ZDOTDIR}/.zshenv" ]] && source "${ZDOTDIR}/.zshenv"

    if [[ -n "${__gallager_visual}" ]]; then
      __gallager_apply_visual() {
        export VISUAL="${__gallager_visual}"
        unset __gallager_visual
        add-zsh-hook -d precmd __gallager_apply_visual 2>/dev/null
        unfunction __gallager_apply_visual 2>/dev/null
      }
      autoload -Uz add-zsh-hook 2>/dev/null
      if ! add-zsh-hook precmd __gallager_apply_visual 2>/dev/null; then
        # Ancient zsh without add-zsh-hook: best-effort immediate set. A later
        # rc file could still override it, but this is better than nothing.
        export VISUAL="${__gallager_visual}"
        unset __gallager_visual
      fi
    fi
    """

    /// The file handed to bash via `--rcfile`. Replicates login startup, then
    /// re-applies VISUAL last.
    static let bashRC = """
    # Gallager shell integration (issue #589) — keep $VISUAL pointing at the
    # in-app `gallager edit` editor even when ~/.bashrc exports its own VISUAL.
    #
    # We are launched as `bash --rcfile <this> -i`, i.e. an interactive
    # non-login shell, because --rcfile is only honored for those. We replicate
    # a login shell's startup ourselves and then re-apply VISUAL last — after
    # the user's startup files — so it wins.

    # Our intended VISUAL, captured before any user file can change it.
    __gallager_visual="${VISUAL}"

    # Replicate `bash -l` startup order: /etc/profile, then the first of the
    # user's personal startup files that exists.
    if [ -r /etc/profile ]; then . /etc/profile; fi
    if [ -r "${HOME}/.bash_profile" ]; then . "${HOME}/.bash_profile"
    elif [ -r "${HOME}/.bash_login" ]; then . "${HOME}/.bash_login"
    elif [ -r "${HOME}/.profile" ]; then . "${HOME}/.profile"
    fi

    if [ -n "${__gallager_visual}" ]; then export VISUAL="${__gallager_visual}"; fi
    unset __gallager_visual
    """
}
