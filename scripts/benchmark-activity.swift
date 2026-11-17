import Foundation
@main struct Bench {
 static func main() async throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-benchmark-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: home) }
  let store = HookStateStore(homeDirectory: home)
  for index in 0..<100 {
   let data=Data("{\"session_id\":\"bench-\(index)\",\"cwd\":\"/tmp/bench\",\"hook_event_name\":\"SessionStart\"}".utf8)
   try store.record(input: JSONDecoder().decode(HookInput.self, from:data),kind:.codex,processID:nil)
  }
  let engine=LiveActivityEngine(homeDirectory:home)
  _ = await engine.reconcile(processes:[])
  let begin=ContinuousClock.now
  for _ in 0..<200 { _ = await engine.handleFileEvents([home.appendingPathComponent(".codex/log/codex-tui.log").path]) }
  print("100 cached hook files, 200 irrelevant events:",begin.duration(to:.now))
  let cachedBegin = ContinuousClock.now
  for _ in 0..<50 { _ = await engine.handleFileEvents([store.directoryURL.path]) }
  print("100 unchanged hook files, 50 reconciliation events:",cachedBegin.duration(to:.now))
 }
}
