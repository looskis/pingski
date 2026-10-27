import Foundation

do {
    switch try CLI.parse(CommandLine.arguments) {
    case .help:
        print(CLI.usage)
    case .version:
        print("pingski \(pingskiVersion)")
    case .openapi:
        print(OpenAPISpec.json)
    case .send(let options):
        exit(SendCommand.run(options))
    case .serve(let config):
        Daemon(config: config).run()
    }
} catch let error as CLIError {
    if error.message == CLI.usage {
        print(CLI.usage)
        exit(0)
    }
    FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
