import Vapor

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let app = try await Application.make(env)
defer { Task { try await app.asyncShutdown() } }

try await configure(app)
try await app.execute()
