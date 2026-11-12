import ArgumentParser

@main
struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "supervox-bench",
                                                    subcommands: [RecordCommand.self, TranscribeCommand.self, LatencyCommand.self])
}
