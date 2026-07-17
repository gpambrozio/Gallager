import Testing

/// Parent container for suites that mutate process-global environment
/// variables (setenv/unsetenv). The `.serialized` trait applies recursively,
/// so every suite nested below (via extensions in sibling files) runs
/// serially with the others — different top-level suites would otherwise run
/// concurrently and race on the shared environment.
@Suite(.serialized)
enum EnvSerializedSuites { }
