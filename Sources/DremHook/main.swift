import DremCore
import Foundation

guard CommandLine.arguments.count == 2,
      let kind = AgentKind(rawValue: CommandLine.arguments[1]) else {
    exit(2)
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(HookInput.self, from: inputData) else {
    exit(2)
}

do {
    try HookStateStore().record(input: input, kind: kind, processID: nil)
} catch {
    exit(1)
}
