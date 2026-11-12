import ArgumentParser

@main
struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "supervox-bench")
}
