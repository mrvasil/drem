import AppKit
import DremCore
import Foundation
import Testing
@testable import Drem

struct TerminalNavigationTests {
    typealias Navigation = TerminalNavigation
    typealias Identity = Navigation.ProcessIdentity

    private let started = Date(timeIntervalSince1970: 10)
    private var app: Navigation.Application {
        .init(pid: 10, kind: .iterm, bundleURL: URL(fileURLWithPath: "/Applications/iTerm.app"))
    }
    private var tree: [Int32: Identity] {
        [30: .init(pid: 30, parentPID: 20, startedAt: started, tty: "/dev/ttys003"),
         // Ghostty inserts /usr/bin/login, whose real UID can remain root.
         20: .init(pid: 20, parentPID: 10, startedAt: started, tty: "/dev/ttys003", userID: 0),
         10: .init(pid: 10, parentPID: 1, startedAt: started, tty: nil)]
    }

    @Test func bindsKernelTTYThroughAncestryNotProjectOrTabTitle() throws {
        let target = try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { tree[$0] })
        #expect(target.tty == "/dev/ttys003")
        #expect(target.application.pid == 10)
        #expect(target.agent.pid == 30)
        #expect(target.terminalProcess == tree[10])
    }

    @Test func rejectsReusedPIDsDetachedAgentsCyclesAndMissingTTY() {
        #expect(throws: Navigation.Failure.staleAgent) {
            try Navigation.resolve(pid: 30, startedAt: .distantPast, applications: [app], read: { tree[$0] })
        }
        #expect(throws: Navigation.Failure.unsupportedTerminal) {
            try Navigation.resolve(pid: 30, startedAt: started, applications: [], read: { tree[$0] })
        }
        var cyclic = tree
        cyclic[20] = .init(pid: 20, parentPID: 30, startedAt: started, tty: "/dev/ttys003")
        #expect(throws: Navigation.Failure.unsupportedTerminal) {
            try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { cyclic[$0] })
        }
        #expect(throws: Navigation.Failure.noTTY) {
            try Navigation.resolve(pid: 10, startedAt: started, applications: [app], read: { tree[$0] })
        }
    }

    @Test func revalidatesAgentAndTerminalAfterPermissionPromptBeforeFocusing() throws {
        let target = try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { tree[$0] })
        for changedPID: Int32 in [30, 10] {
            var calls = 0
            #expect(throws: Navigation.Failure.staleAgent) {
                try Navigation.focus(target, read: { $0 == changedPID ? nil : tree[$0] }, execute: { _ in
                    calls += 1
                    return UUID().uuidString
                })
            }
            #expect(calls == 1, "No focus event after process exit/reuse while permission was pending")
        }
        var scripts: [String] = []
        let id = UUID().uuidString
        try Navigation.focus(target, read: { tree[$0] }, execute: { script in
            scripts.append(script)
            return scripts.count == 1 ? id : "focused"
        })
        #expect(scripts.count == 2)
        #expect(!scripts[0].contains("activate"))
        #expect(!scripts[0].contains("select (item"))
        #expect(scripts[1].contains(id))
        #expect(scripts[1].contains("select (item 1 of chosen)"))
        #expect(scripts[1].contains("select (item 2 of chosen)"))
        #expect(scripts[1].contains("select (item 3 of chosen)"))
        #expect(scripts.allSatisfy { $0.contains("if (count of matches) is not 1") })
    }

    @Test func permissionsAndAmbiguityNeverFallBackToActivatingTheWrongTab() throws {
        let target = try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { tree[$0] })
        for failure: Navigation.Failure in [.permission, .ambiguous, .timeout, .missing] {
            var calls = 0
            #expect(throws: failure) {
                try Navigation.focus(target, read: { tree[$0] }, execute: { _ in calls += 1; throw failure })
            }
            #expect(calls == 1)
        }
    }

    @Test func metadataIsWhitelistedAndNoTerminalTextOrCommandsAreRead() throws {
        #expect(Navigation.normalizeTTY("ttys003") == "/dev/ttys003")
        #expect(Navigation.normalizeTTY("/dev/ttys003") == "/dev/ttys003")
        for value in ["??", "tty", "", "/dev/../ttys003", "ttys003\n", "ttys003\"", "tty;command"] {
            #expect(Navigation.normalizeTTY(value) == nil)
        }
        for value in ["", "\"\nactivate", "x y", "x\\y", String(repeating: "x", count: 129)] {
            #expect(!Navigation.validTerminalID(value))
        }
        let target = try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { tree[$0] })
        #expect(Navigation.script(for: target, terminalID: "\"\nactivate") == "return \"missing\"")
        for source in [Navigation.script(for: target, terminalID: nil), Navigation.script(for: target, terminalID: UUID().uuidString)] {
            for forbidden in ["do shell script", "write text", "send key", "contents of", "name of", "working directory"] {
                #expect(!source.contains(forbidden))
            }
        }
    }

    @Test func ghosttyRequiresARealTTYPropertyNotJustTerminalIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Terminal-\(UUID())")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ghostty = Navigation.Application(pid: 10, kind: .ghostty, bundleURL: root)
        let dictionary = resources.appendingPathComponent("Ghostty.sdef")
        try Data(#"<dictionary><suite><class name="terminal"><property name="id"/></class></suite></dictionary>"#.utf8).write(to: dictionary)
        #expect(!Navigation.supportsExactNavigation(ghostty))
        try Data(#"<dictionary><suite><class name="terminal"><property name="tty"/></class></suite></dictionary>"#.utf8).write(to: dictionary)
        #expect(Navigation.supportsExactNavigation(ghostty))
        let target = Navigation.Target(agent: tree[30]!, application: ghostty, terminalProcess: tree[10]!, tty: "/dev/ttys003")
        #expect(Navigation.script(for: target, terminalID: UUID().uuidString).contains("focus chosen"))
    }

    @Test func kernelIdentityMatchesLivenessAndRejectsInvalidPIDs() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let identity = try #require(Identity.read(pid))
        #expect(identity.pid == pid)
        #expect(identity.parentPID == getppid())
        #expect(identity.startedAt == ProcessLiveness.startTime(pid))
        #expect(Identity.read(-1) == nil)
        #expect(Identity.read(0) == nil)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_TERMINAL_SCRIPT_CHECK"] == "1"))
    func compileAgainstInstalledTerminalDictionaryWithoutExecuting() throws {
        // No app activation or focus in this fixture; compile only.
        let target = try Navigation.resolve(pid: 30, startedAt: started, applications: [app], read: { tree[$0] })
        for id in [nil, UUID().uuidString] {
            let script = try #require(NSAppleScript(source: Navigation.script(for: target, terminalID: id)))
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            #expect(compiled, "\(String(describing: error))")
        }
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_TERMINAL_PROBE_PID"] != nil))
    func inspectLiveBindingWithoutSendingAppleEvents() throws {
        let pid = try #require(Int32(ProcessInfo.processInfo.environment["DREM_TERMINAL_PROBE_PID"] ?? ""))
        let identity = try #require(Identity.read(pid))
        let applications = Navigation.runningApplications()
        print("terminal-probe applications: \(applications.map { "\($0.kind.name):\($0.pid)" })")
        var current: Int32 = pid
        for _ in 0..<8 {
            guard let info = Identity.read(current) else { print("terminal-probe unreadable PID: \(current)"); break }
            print("terminal-probe ancestry: \(info.pid) parent=\(info.parentPID) uid=\(info.userID)")
            current = info.parentPID
        }
        let target = try Navigation.resolve(pid: pid, startedAt: identity.startedAt, applications: applications)
        print("terminal-probe: \(target.application.kind.name) \(target.tty) exact=\(Navigation.supportsExactNavigation(target.application))")
    }
}
