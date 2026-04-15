import ArgumentParser

@main
struct GallagerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gallager",
        abstract: "Control Gallager from the command line",
        subcommands: [PingCommand.self]
    )
}

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check if Gallager is running"
    )

    func run() throws {
        print("ping placeholder")
    }
}
