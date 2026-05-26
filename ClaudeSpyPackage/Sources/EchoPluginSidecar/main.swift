import Foundation
import Logging

// Route logs to stderr so the JSON-RPC frames on stdout aren't polluted.
// The parent supervisor's log-file capture sees stderr verbatim.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .info
    return handler
}

let sidecar = EchoSidecar()
do {
    try await sidecar.run()
} catch {
    FileHandle.standardError.write(
        Data("[echo-plugin sidecar] fatal: \(error)\n".utf8)
    )
    exit(1)
}
