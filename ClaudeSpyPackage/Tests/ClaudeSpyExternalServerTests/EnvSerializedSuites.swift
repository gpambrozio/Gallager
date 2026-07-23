import Testing

/// Parent container for the suites that boot full Vapor applications. The
/// `.serialized` trait applies recursively, so every suite nested below (via
/// extensions in sibling files) runs serially with the others, bounding how
/// many relay servers run at once.
///
/// ## Never `setenv` in unit tests
///
/// These suites used to configure the app by mutating process-global
/// environment variables (`setenv`/`unsetenv`), which this container
/// serialized against each other. That was still unsafe: other test targets in
/// the same process spawn subprocesses concurrently, and `posix_spawn` reads
/// the live `environ` array — a concurrent `setenv` can realloc it mid-spawn,
/// failing the spawn with EFAULT ("Bad address"). Serialization can't fix that
/// (the racing suites are in other targets); config injection does. Pass test
/// configuration via `configure(_:env:)` instead.
@Suite(.serialized)
enum EnvSerializedSuites { }
