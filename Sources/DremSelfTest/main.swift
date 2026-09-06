import DremCore
import Darwin
import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

expect(
    ProcessLiveness.isAlive(ProcessInfo.processInfo.processIdentifier),
    "current process liveness"
)
expect(!ProcessLiveness.isAlive(-1), "invalid process is not alive")

let codexLine: Substring = "  98903 79499 04-15:08:26 S+ codex codex --dangerously-bypass-approvals-and-sandbox resume abc"[...]
let codex = ProcessScanner.parse(line: codexLine)
expect(codex?.kind == .codex, "native Codex classification")
expect(codex?.id == 98903, "Codex PID parsing")
expect(codex?.parentPID == 79499, "Codex parent PID parsing")
expect(codex?.elapsed == "04-15:08:26", "Codex elapsed-time parsing")
expect(codex?.sessionIDHint == "abc", "Codex resumed session hint parsing")

let claudeLine: Substring = "  45688 43415 09-17:41:16 S+ claude claude --resume abc"[...]
let claude = ProcessScanner.parse(line: claudeLine)
expect(claude?.kind == .claude, "native Claude classification")
expect(claude?.id == 45688, "Claude PID parsing")
expect(claude?.sessionIDHint == "abc", "Claude resumed session hint parsing")

expect(
    ProcessScanner.classify(
        command: "/opt/homebrew/bin/node",
        arguments: "node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
    ) == .codex,
    "Codex Node wrapper classification"
)
expect(
    ProcessScanner.classify(
        command: "node",
        arguments: "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    ) == .claude,
    "Claude Node wrapper classification"
)

expect(
    ProcessScanner.classify(
        command: "/path/codex-code-mode-host",
        arguments: "/path/codex-code-mode-host"
    ) == nil,
    "helper exclusion"
)
expect(
    ProcessScanner.classify(command: "rg", arguments: "rg -i codex|claude") == nil,
    "text-search exclusion"
)
expect(
    ProcessScanner.classify(command: "zsh", arguments: "ps aux | grep claude") == nil,
    "shell-command exclusion"
)

expect(
    ProcessScanner.classify(
        command: "/Applications/Cha",
        arguments: "/Applications/ChatGPT.app/Contents/Resources/codex app-server"
    ) == .codex,
    "ChatGPT embedded Codex classification"
)

let codexWorking = """
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary"}}
"""
expect(ActivityLogScanner.classifyCodexLog(codexWorking) == .working, "Codex working state")
expect(
    ActivityLogScanner.classifyCodexLog("""
    {"timestamp":"2026-09-05T21:00:00.123Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec"}}
    """) == .working,
    "a long task remains detectable after its task_started marker leaves the bounded tail"
)

let codexIdle = codexWorking + "\n" + """
{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}
"""
expect(ActivityLogScanner.classifyCodexLog(codexIdle) == .idle, "Codex idle state")

let codexInterrupted = codexWorking + "\n" + """
{"type":"event_msg","payload":{"type":"turn_aborted"}}
"""
expect(ActivityLogScanner.classifyCodexLog(codexInterrupted) == .idle, "Codex interrupted state")

let claudeWorking = """
{"type":"user","sessionId":"abc","cwd":"/tmp/project"}
{"type":"assistant","message":{"stop_reason":"tool_use"}}
"""
expect(ActivityLogScanner.classifyClaudeLog(claudeWorking) == .working, "Claude working state")

let claudeIdle = claudeWorking + "\n" + """
{"type":"assistant","message":{"stop_reason":"end_turn"}}
"""
expect(ActivityLogScanner.classifyClaudeLog(claudeIdle) == .idle, "Claude idle state")

let incrementalRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("drem-incremental-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: incrementalRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: incrementalRoot) }

let incrementalLog = incrementalRoot.appendingPathComponent("session.jsonl")
let incrementalStart = """
{"type":"session_meta","payload":{"id":"incremental-session","cwd":"/tmp/project"}}
{"type":"event_msg","payload":{"type":"task_started"}}

"""
try Data(incrementalStart.utf8).write(to: incrementalLog)

let incrementalScanner = IncrementalTranscriptScanner()
let firstIncrementalResult = incrementalScanner.consume(url: incrementalLog, kind: .codex)
expect(firstIncrementalResult?.session.state == .working, "incremental scanner initial state")
expect(firstIncrementalResult?.wasIncremental == false, "first transcript read is initial")

let appendedStop = """
{"type":"event_msg","payload":{"type":"task_complete"}}

"""
if let handle = try? FileHandle(forWritingTo: incrementalLog) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appendedStop.utf8))
    try handle.close()
}

let secondIncrementalResult = incrementalScanner.consume(url: incrementalLog, kind: .codex)
expect(secondIncrementalResult?.session.state == .idle, "incremental scanner appended state")
expect(secondIncrementalResult?.wasIncremental == true, "later transcript read is incremental")
expect(
    (secondIncrementalResult?.bytesRead ?? Int.max) == Data(appendedStop.utf8).count,
    "incremental scanner reads only appended bytes"
)

if let handle = try? FileHandle(forWritingTo: incrementalLog) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"timestamp":"2030-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count"}}
    {"timestamp":"2030-01-01T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output"}}

    """.utf8))
    try handle.close()
}
let lateOutput = incrementalScanner.consume(url: incrementalLog, kind: .codex)
expect(lateOutput?.session.state == .idle, "late output cannot reopen a completed task")
expect(
    lateOutput?.session.updatedAt == secondIncrementalResult?.session.updatedAt,
    "bookkeeping does not make old activity evidence newer"
)
let unchangedResult = incrementalScanner.consume(url: incrementalLog, kind: .codex)
expect(unchangedResult?.bytesRead == 0, "unchanged idle transcript reads no content")

let mappedHome = incrementalRoot.appendingPathComponent("mapped-home", isDirectory: true)
let mappedSessionDirectory = mappedHome
    .appendingPathComponent(".codex/sessions/2026/09/04", isDirectory: true)
try FileManager.default.createDirectory(at: mappedSessionDirectory, withIntermediateDirectories: true)
let mappedLog = mappedSessionDirectory.appendingPathComponent("mapped.jsonl")
try Data("""
{"type":"session_meta","payload":{"id":"mapped-session","cwd":"/tmp/mapped-project"}}
{"type":"event_msg","payload":{"type":"task_started"}}

""".utf8).write(to: mappedLog)

let mappedProcess = DetectedAgentProcess(
    id: 4242,
    parentPID: 42,
    kind: .codex,
    elapsed: "00:01",
    state: "S",
    command: "codex",
    workingDirectory: "/tmp/mapped-project",
    openTranscriptPaths: [mappedLog.path]
)
let mappedSnapshot = ActivityLogScanner(homeDirectory: mappedHome).scan(processes: [mappedProcess])
expect(
    mappedSnapshot.status(for: .codex).sessions.first?.processID == 4242,
    "transcript session is linked to the process holding its log"
)

let hintedHome = incrementalRoot.appendingPathComponent("hinted-home", isDirectory: true)
let hintedDirectory = hintedHome
    .appendingPathComponent(".claude/projects/shared", isDirectory: true)
try FileManager.default.createDirectory(at: hintedDirectory, withIntermediateDirectories: true)

let resumedLog = hintedDirectory.appendingPathComponent("resumed-session.jsonl")
try Data("""
{"type":"user","sessionId":"resumed-session","cwd":"/tmp/shared-project"}
{"type":"assistant","sessionId":"resumed-session","message":{"stop_reason":"end_turn"}}

""".utf8).write(to: resumedLog)

let unrelatedLog = hintedDirectory.appendingPathComponent("unrelated-session.jsonl")
try Data("""
{"type":"user","sessionId":"unrelated-session","cwd":"/tmp/shared-project"}
{"type":"assistant","sessionId":"unrelated-session","message":{"stop_reason":"tool_use"}}

""".utf8).write(to: unrelatedLog)

try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 100)],
    ofItemAtPath: resumedLog.path
)
try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 200)],
    ofItemAtPath: unrelatedLog.path
)

let resumedProcess = DetectedAgentProcess(
    id: 5252,
    parentPID: 52,
    kind: .claude,
    elapsed: "01:00",
    state: "S+",
    command: "claude --resume resumed-session",
    workingDirectory: "/tmp/shared-project",
    sessionIDHint: "resumed-session"
)
let hintedSnapshot = ActivityLogScanner(homeDirectory: hintedHome).scan(processes: [resumedProcess])
let hintedSessions = hintedSnapshot.status(for: .claude).sessions
expect(hintedSessions.count == 1, "resumed process ignores unrelated newer transcript in same cwd")
expect(hintedSessions.first?.id == "resumed-session", "resumed process selects its exact session")
expect(hintedSessions.first?.state == .idle, "resumed idle session is not reported as working")

let exitEngine = LiveActivityEngine(homeDirectory: mappedHome)
let beforeProcessExit = await exitEngine.reconcile(processes: [mappedProcess])
expect(
    beforeProcessExit.snapshot.status(for: .codex).state == .working,
    "mapped session is working before process exit"
)

if let handle = try? FileHandle(forWritingTo: mappedLog) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"type":"event_msg","payload":{"type":"task_complete"}}

    """.utf8))
    try handle.close()
}
let afterSilentStop = await exitEngine.recheckWorkingTranscripts()
expect(
    afterSilentStop.snapshot.status(for: .codex).state == .idle,
    "periodic transcript recheck detects a missed task completion"
)

if let handle = try? FileHandle(forWritingTo: mappedLog) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("""
    {"type":"event_msg","payload":{"type":"task_started"}}

    """.utf8))
    try handle.close()
}
let afterSilentStart = await exitEngine.recheckWorkingTranscripts()
expect(
    afterSilentStart.snapshot.status(for: .codex).state == .working,
    "periodic transcript recheck also detects a missed task start from idle"
)

let afterProcessExit = await exitEngine.processExited(4242)
expect(
    afterProcessExit.snapshot.status(for: .codex).state == .offline,
    "mapped session becomes offline after abrupt process exit"
)
expect(
    afterProcessExit.snapshot.status(for: .codex).sessions.isEmpty,
    "abrupt process exit removes its transcript session"
)

expect(HookStateStore.activity(for: "UserPromptSubmit") == .working, "hook start state")
expect(HookStateStore.activity(for: "Stop") == .idle, "hook stop state")
expect(HookStateStore.activity(for: "Interrupt") == .idle, "hook interrupt state")
expect(HookStateStore.activity(for: "SessionEnd") == .offline, "hook session-end state")

let hookHome = incrementalRoot.appendingPathComponent("hook-home", isDirectory: true)
let hookInputData = Data("""
{"session_id":"hook-session","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}
""".utf8)
let hookInput = try JSONDecoder().decode(HookInput.self, from: hookInputData)
let hookStore = HookStateStore(homeDirectory: hookHome)
try hookStore.record(input: hookInput, kind: .codex, processID: nil)
let hookRecords = hookStore.readAll()
expect(hookRecords.count == 1, "hook state is readable without PID lookup")
expect(hookRecords.first?.state == .working, "hook state preserves working activity")

// Reproduce a stale SessionStart hook masking a later task in the same session.
let staleHookHome = incrementalRoot.appendingPathComponent("stale-hook-home", isDirectory: true)
let staleHookDirectory = staleHookHome.appendingPathComponent(".codex/sessions", isDirectory: true)
try FileManager.default.createDirectory(at: staleHookDirectory, withIntermediateDirectories: true)
let staleHookLog = staleHookDirectory.appendingPathComponent("active.jsonl")
let staleStart = try JSONDecoder().decode(HookInput.self, from: Data("""
{"session_id":"active-session","cwd":"/tmp/active-project","hook_event_name":"SessionStart"}
""".utf8))
try HookStateStore(homeDirectory: staleHookHome).record(input: staleStart, kind: .codex, processID: nil)
let newTaskDate = Date().addingTimeInterval(2)
let newTaskStamp = ISO8601DateFormatter().string(from: newTaskDate)
try Data("""
{"type":"session_meta","payload":{"id":"active-session","cwd":"/tmp/active-project"}}
{"timestamp":"\(newTaskStamp)","type":"event_msg","payload":{"type":"task_started"}}

""".utf8).write(to: staleHookLog)
try FileManager.default.setAttributes([.modificationDate: newTaskDate], ofItemAtPath: staleHookLog.path)
let activeProcess = DetectedAgentProcess(
    id: 6262, parentPID: 62, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
    workingDirectory: "/tmp/active-project", openTranscriptPaths: [staleHookLog.path]
)
let staleHookEngine = LiveActivityEngine(homeDirectory: staleHookHome)
let staleHookState = await staleHookEngine.reconcile(processes: [activeProcess])
expect(
    staleHookState.snapshot.status(for: .codex).state == .working,
    "newer transcript activity overrides a stale idle SessionStart hook"
)

let stopHook = try JSONDecoder().decode(HookInput.self, from: Data("""
{"session_id":"active-session","cwd":"/tmp/active-project","hook_event_name":"Stop"}
""".utf8))
try HookStateStore(homeDirectory: staleHookHome).record(input: stopHook, kind: .codex, processID: nil)
try Data("""
{"type":"session_meta","payload":{"id":"active-session","cwd":"/tmp/active-project"}}
{"timestamp":"2020-01-01T00:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2030-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count"}}

""".utf8).write(to: staleHookLog)
try FileManager.default.setAttributes([.modificationDate: newTaskDate], ofItemAtPath: staleHookLog.path)
let stoppedHookState = await staleHookEngine.reconcile(processes: [activeProcess])
expect(
    stoppedHookState.snapshot.status(for: .codex).state == .idle,
    "newer Stop hook wins over old work even when file modification is newer"
)

// A bounded byte tail may start in the middle of a Russian UTF-8 character.
// That partial first line must not discard the complete task event after it.
let unicodeHome = incrementalRoot.appendingPathComponent("unicode-home", isDirectory: true)
let unicodeDirectory = unicodeHome.appendingPathComponent(".codex/sessions", isDirectory: true)
try FileManager.default.createDirectory(at: unicodeDirectory, withIntermediateDirectories: true)
let unicodeLog = unicodeDirectory.appendingPathComponent("unicode.jsonl")
var unicodeBytes = Data("""
{"type":"session_meta","payload":{"id":"unicode-session","cwd":"/tmp/unicode-project"}}
{"type":"padding","text":"\(String(repeating: "я", count: 3 * 1024 * 1024))"}
{"type":"event_msg","payload":{"type":"task_started"}}

""".utf8)
if unicodeBytes[unicodeBytes.count - 4 * 1024 * 1024] < 0x80
    || unicodeBytes[unicodeBytes.count - 4 * 1024 * 1024] >= 0xC0 {
    unicodeBytes.append(0x0A)
}
try unicodeBytes.write(to: unicodeLog)
let unicodeProcess = DetectedAgentProcess(
    id: 6363, parentPID: 63, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
    workingDirectory: "/tmp/unicode-project", openTranscriptPaths: [unicodeLog.path]
)
let unicodeState = ActivityLogScanner(homeDirectory: unicodeHome).scan(processes: [unicodeProcess])
expect(unicodeState.hasWorkingAgent, "UTF-8 byte boundaries cannot hide a working session")

expect(KeepAwakePolicy.sanitizedDuration(120) == 120, "valid keep-awake duration")
expect(KeepAwakePolicy.sanitizedDuration(17) == 0, "invalid keep-awake duration falls back")
expect(KeepAwakePolicy.sanitizedBatteryLimit(15) == 15, "valid battery limit")
expect(KeepAwakePolicy.sanitizedBatteryLimit(99) == 10, "invalid battery limit falls back")
expect(
    KeepAwakePolicy.sanitizedMouseJiggleInterval(10) == 10,
    "valid pointer interval"
)
expect(
    KeepAwakePolicy.sanitizedMouseJiggleInterval(3) == 5,
    "invalid pointer interval falls back"
)

expect(
    !KeepAwakeAutomationSupport.hasExternalDisplay(builtInFlags: [true]),
    "built-in display alone is not external"
)
expect(
    KeepAwakeAutomationSupport.hasExternalDisplay(builtInFlags: [true, false]),
    "external display is detected"
)
let automaticConditions = KeepAwakeAutomationSupport.matchingConditions(
    externalDisplayEnabled: true,
    externalDisplayConnected: true,
    powerEnabled: true,
    connectedToPower: true
)
expect(
    automaticConditions == [.externalDisplay, .power],
    "all matching automatic conditions are retained"
)
expect(
    KeepAwakeAutomationSupport.action(
        matchingConditions: automaticConditions,
        sessionActive: false,
        automaticSessionActive: false
    ) == .activate,
    "automation starts an inactive session"
)
expect(
    KeepAwakeAutomationSupport.action(
        matchingConditions: [],
        sessionActive: true,
        automaticSessionActive: true
    ) == .deactivate,
    "automation ends when its conditions clear"
)
expect(
    KeepAwakeAutomationSupport.action(
        matchingConditions: automaticConditions,
        sessionActive: true,
        automaticSessionActive: false
    ) == .none,
    "automation does not replace a manual session"
)
expect(
    KeepAwakeAutomationSupport.isScreenLocked(
        sessionDictionary: ["CGSSessionScreenIsLocked": NSNumber(value: true)]
    ),
    "numeric screen-lock state is understood"
)
expect(
    !KeepAwakeAutomationSupport.isScreenLocked(sessionDictionary: nil),
    "unreadable screen-lock state does not strand a paused session"
)

expect(
    KeepAwakeSudoersSupport.sleepDisabled(inPmsetOutput: " SleepDisabled  1\n"),
    "pmset disabled-sleep state is parsed"
)
expect(
    !KeepAwakeSudoersSupport.sleepDisabled(inPmsetOutput: " SleepDisabled  0\n"),
    "pmset normal-sleep state is parsed"
)
expect(
    KeepAwakeSudoersSupport.clamshellRule(uid: 501)
        == "#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0",
    "closed-lid permission is restricted to two pmset commands"
)
expect(
    KeepAwakeSudoersSupport.clamshellRule(uid: uid_t.max)
        .range(of: #"^#[0-9]+ [A-Za-z0-9()=:,./ ]+$"#, options: .regularExpression) != nil,
    "closed-lid permission never contains shell or sudoers metacharacters"
)

// Exercise the same policy consumed by the live manager, including two agents
// finishing independently and an open-but-idle CLI that must not hold sleep.
func agentConditions(enabled: Bool = true, working: Bool) -> Set<KeepAwakeAutomationCondition> {
    KeepAwakeAutomationSupport.matchingConditions(
        externalDisplayEnabled: false, externalDisplayConnected: false,
        powerEnabled: false, connectedToPower: false,
        agentsEnabled: enabled, hasWorkingAgent: working
    )
}
expect(agentConditions(enabled: false, working: true).isEmpty, "agent mode is opt-in")
expect(agentConditions(working: false).isEmpty, "idle processes do not trigger wake automation")
var agentSessionActive = false
for (workingCount, expectedAction) in [
    (0, KeepAwakeAutomationAction.none), (1, .activate), (2, .none),
    (1, .none), (0, .deactivate), (1, .activate), (0, .deactivate),
] {
    let action = KeepAwakeAutomationSupport.action(
        matchingConditions: agentConditions(working: workingCount > 0),
        sessionActive: agentSessionActive, automaticSessionActive: agentSessionActive
    )
    expect(action == expectedAction, "agent count \(workingCount) transitions to \(expectedAction)")
    if action == .activate { agentSessionActive = true }
    if action == .deactivate { agentSessionActive = false }
}
expect(
    KeepAwakeAutomationSupport.action(
        matchingConditions: [], sessionActive: true, automaticSessionActive: false
    ) == .none,
    "non-agent automation does not cancel an explicit manual session"
)
expect(
    !KeepAwakeAgentPolicy.requiresWake(enabled: true, hasWorkingAgent: true, suppressed: true),
    "manual stop suppresses the current agent wake request"
)
expect(
    !KeepAwakeAgentPolicy.shouldPauseForLock(locked: true, pauseEnabled: true, agentRequiresWake: true),
    "locking the screen cannot cancel closed-lid agent work"
)
expect(
    KeepAwakeAgentPolicy.shouldPauseForLock(locked: true, pauseEnabled: true, agentRequiresWake: false),
    "screen-lock policy resumes after the final agent finishes"
)
for manual in [false, true] {
    for working in [false, true] {
        expect(
            KeepAwakeAgentPolicy.requiresClamshell(manualPreference: manual, agentRequiresWake: working)
                == (manual || working),
            "manual and agent lid demand are independent"
        )
    }
}

var lidState = KeepAwakeClamshellState()
expect(lidState.request(false) == nil, "idle lid mode does not launch a subprocess")
expect(lidState.request(true) == true, "first task requests lid protection")
expect(lidState.request(true) == nil, "duplicate events do not duplicate system writes")
expect(lidState.request(false) == nil, "task completion while enabling waits for the pending write")
expect(lidState.complete(success: true) == false, "late enable is followed by sleep restoration")
expect(lidState.complete(success: true) == nil && !lidState.active, "last task leaves normal lid sleep")
expect(lidState.request(true) == true, "another task can start")
expect(lidState.complete(success: true) == nil && lidState.active, "lid protection becomes active")
expect(lidState.request(false) == false, "completion requests sleep restoration")
expect(lidState.request(true) == nil, "new task during restoration is queued")
expect(lidState.complete(success: true) == true, "new task re-enables after restoration completes")
expect(lidState.complete(success: true) == nil && lidState.active, "latest desired state wins")
expect(lidState.request(false) == false, "cleanup requests restoration")
expect(lidState.complete(success: false) == nil && lidState.active, "failed restore remains visible without a retry loop")
expect(lidState.request(false) == false, "explicit cleanup can retry a failed restore")
expect(lidState.complete(success: true) == nil && !lidState.active, "retry releases lid protection")

let sleepAssertions = SleepAssertionController()
defer { sleepAssertions.deactivate() }
do {
    try sleepAssertions.activate(allowDisplaySleep: false)
    expect(sleepAssertions.hasSystemAssertion, "system sleep assertion is created")
    expect(sleepAssertions.hasDisplayAssertion, "display sleep assertion is created")

    try sleepAssertions.activate(allowDisplaySleep: true)
    expect(sleepAssertions.hasSystemAssertion, "system assertion survives display preference change")
    expect(!sleepAssertions.hasDisplayAssertion, "display assertion follows display-sleep preference")

    sleepAssertions.deactivate()
    expect(!sleepAssertions.hasSystemAssertion, "system sleep assertion is released")
    expect(!sleepAssertions.hasDisplayAssertion, "display sleep assertion is released")
} catch {
    failures.append("IOKit sleep assertion lifecycle: \(error.localizedDescription)")
}

if failures.isEmpty {
    print("Drem self-test: all checks passed")
} else {
    for failure in failures {
        FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
    }
    exit(1)
}
