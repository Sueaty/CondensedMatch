import Foundation
import MatchCore

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: swift run match-benchmark <fixtures.json>"])
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixtures = try JSONDecoder().decode([BenchmarkCase].self, from: Data(contentsOf: url))
    let result = try fixtures.map(Benchmark.evaluate)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(result))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
