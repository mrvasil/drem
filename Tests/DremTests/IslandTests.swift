import AppKit
import Combine
import DremCore
import Foundation
import SwiftUI
import Testing
@testable import Drem

@MainActor
@Suite(.serialized)
struct IslandTests {
    @Test func actionSymbolsAreDistinctAvailableAndDoNotGuessToolCapabilities() throws {
        let expected: [(AgentActivityDetail.Action, String)] = [
            (.working, "sparkles"), (.reading, "doc.text.magnifyingglass"),
            (.editing, "square.and.pencil"), (.tool, "wrench.and.screwdriver"),
            (.compacting, "arrow.down.right.and.arrow.up.left")
        ]
        #expect(Set(expected.map { $0.0.islandSymbol }).count == expected.count)
        for (action, symbol) in expected {
            #expect(action.islandSymbol == symbol)
            _ = try #require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        }
    }

    @Test func actionIconsFollowEvidenceRegardlessOfPublicTextVisibility() throws {
        for action: AgentActivityDetail.Action in [.working, .reading, .editing, .tool, .compacting] {
            let session = AgentSessionActivity(id: "icons", kind: .codex, state: .working, updatedAt: .now,
                projectName: "drem", processID: 1, source: .transcript,
                detail: AgentActivityDetail(action: action, publicStatus: "Public commentary", headline: "Public heading"))
            let snapshot = AgentSnapshot(statuses: [AgentStatus(kind: .codex, state: .working,
                runningProcessCount: 1, sessions: [session])])
            let row = try #require(IslandRow.rows(snapshot).first)
            #expect(row.activity == action)
            #expect(row.activity.islandSymbol == action.islandSymbol)
            #expect(row.title(showStatus: true) == "Public heading")
            #expect(row.title(showStatus: false) == action.title)
            #expect(!row.copyText(showStatus: false).contains("Public"))
        }
    }

    @Test func attentionTakesPriorityWithoutStealingSelectionOrChangingSleep() throws {
        let model = IslandPresentation()
        model.lifecycle.configure(enabled: true, available: true)
        let working = IslandRow(id: "a", kind: .codex, project: "drem", action: "Работает", status: nil)
        let waiting = IslandRow(id: "b", kind: .claude, project: "website", action: "Использует инструмент",
            status: "Private text", headline: "Private heading", sessionTitle: "Private name", attention: .permission)
        model.replaceRows([working, waiting])
        model.lifecycle.activityChanged(count: 2)
        #expect(model.featuredRow?.id == "b")
        #expect(model.attentionCount == 1)
        #expect(model.rows.map(\.id) == ["a", "b"], "Do not move cards under the cursor")
        model.select("a")
        #expect(model.featuredRow?.id == "a", "Do not steal an explicit detail selection")
        model.showOverview()
        #expect(model.featuredRow?.id == "b")
        model.hoveredID = "a"
        #expect(model.featuredRow?.id == "a")
        #expect(!model.sleep.preventsSleep, "Attention never owns or infers wake protection")
        #expect(waiting.title(showStatus: true) == "Ждёт разрешения")
        #expect(waiting.title(showStatus: false) == "Ждёт разрешения")
        #expect(!waiting.copyText(showStatus: false).contains("Private"))
        #expect(waiting.copyText(showStatus: false).contains("Ждёт разрешения"))
        for attention: AgentAttention in [.permission, .question] {
            _ = try #require(NSImage(systemSymbolName: attention.islandSymbol, accessibilityDescription: nil))
        }
    }

    @Test func idleAttentionCannotBecomeAnIslandRowOrHoldTheLifecycleOpen() {
        let session = AgentSessionActivity(id: "waiting", kind: .claude, state: .idle,
            updatedAt: .now, projectName: "demo", processID: nil, source: .hook,
            detail: AgentActivityDetail(attention: .permission))
        let snapshot = AgentSnapshot(statuses: [AgentStatus(kind: .claude, state: .idle,
            runningProcessCount: 1, sessions: [session])])
        let model = IslandPresentation()
        model.receive(snapshot)
        #expect(model.rows.isEmpty)
        #expect(model.attentionCount == 0)
        #expect(model.lifecycle.workingCount == 0)
    }

    @Test(arguments: [false, true])
    func completedAttentionDoesNotSurviveInTheFeaturedSnapshot(closed: Bool) throws {
        for attention: AgentAttention in [.permission, .question] {
            let model = IslandPresentation()
            model.lifecycle.configure(enabled: true, available: true)
            func snapshot(_ state: AgentActivity) -> AgentSnapshot {
                let session = AgentSessionActivity(id: "waiting", kind: .claude, state: state,
                    updatedAt: .now, projectName: "demo", processID: nil, source: .hook,
                    detail: AgentActivityDetail(attention: attention))
                return AgentSnapshot(statuses: [AgentStatus(kind: .claude, state: state,
                    runningProcessCount: 1, sessions: [session])])
            }
            model.receive(snapshot(.working))
            #expect(model.featuredRow?.attention == attention)
            model.receive(closed ? AgentSnapshot(statuses: []) : snapshot(.idle))
            let completion = try #require(model.completions.first)
            #expect(completion.closed == closed)
            #expect(completion.row.attention == nil)
            #expect(model.featuredRow?.attention == nil, "Completion fallback must not ask for attention")
            #expect(model.attentionCount == 0)
            #expect(model.lifecycle.workingCount == 0)
            #expect(model.lifecycle.mode == .completed)
            #expect(!model.sleep.preventsSleep)
        }
    }

    @Test func compactAndHoverStayInsideMenuBarAndCameraHasAnInvisibleClickTarget() {
        let model = IslandPresentation()
        model.notchHeight = 32
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 1)
        #expect(model.height == 32)
        model.lifecycle.hover(true)
        #expect(model.height == 32, "Hover cannot cover the app beneath the menu bar")
        let target = IslandHitRegion.notchTarget(centerX: 500, screenTop: 1000, width: 185, height: 32)
        #expect(target.contains(CGPoint(x: 500, y: 960)), "Click 8pt below the physical camera")
        #expect(!target.contains(CGPoint(x: 500, y: 940)), "Do not capture application content farther down")
        #expect(!target.contains(CGPoint(x: 650, y: 980)))
    }

    @Test func swipesHideLeftRightUpAndRestoreLeftRightDown() {
        for inverted in [false, true] {
            for intent: IslandSwipe.Intent in [.hide, .restore] {
                for (x, y): (CGFloat, CGFloat) in [(-25, 0), (25, 0), (0, intent == .hide ? 25 : -25)] {
                    var gesture = IslandSwipe()
                    let rawY = inverted ? -y : y
                    #expect(gesture.consume(x: x, y: rawY, inverted: inverted, precise: true,
                        timestamp: 1, phase: .began, momentum: false, intent: intent).resolution == nil)
                    #expect(gesture.consume(x: x, y: rawY, inverted: inverted, precise: true,
                        timestamp: 1.1, phase: .changed, momentum: false, intent: intent).feedback?.ready == true)
                    #expect(gesture.finish(at: 1.2).resolution == .commit(intent))
                }
            }
        }
    }

    @Test func onePhysicalSwipeCannotHideAndImmediatelyRestoreEvenAfterAPause() {
        var gesture = IslandSwipe()
        #expect(gesture.consume(x: 50, y: 0, inverted: false, precise: true,
            timestamp: 1, phase: .began, momentum: false, intent: .hide).feedback?.ready == true)
        #expect(gesture.finish(at: 1.01).resolution == .commit(.hide))
        for time in [1.1, 1.8, 2.2] {
            #expect(gesture.consume(x: 100, y: 0, inverted: false, precise: true,
                timestamp: time, phase: .changed, momentum: false, intent: .restore).captured == false)
        }
        #expect(gesture.consume(x: 0, y: 0, inverted: false, precise: true,
            timestamp: 2.3, phase: .ended, momentum: false, intent: .restore).captured == false)
        #expect(gesture.consume(x: 100, y: 0, inverted: false, precise: true,
            timestamp: 2.4, phase: .none, momentum: true, intent: .restore).captured == false)
        #expect(gesture.consume(x: -50, y: 0, inverted: false, precise: true,
            timestamp: 2.5, phase: .began, momentum: false, intent: .restore).feedback?.ready == true)
        #expect(gesture.finish(at: 2.51).resolution == .commit(.restore))
        #expect(gesture.consume(x: -100, y: 0, inverted: false, precise: true,
            timestamp: 2.6, phase: .changed, momentum: false, intent: .hide).captured == false)
    }

    @Test func gestureRestorationIsCompactAndClickStillExpands() {
        var state = IslandLifecycle()
        state.configure(enabled: true, available: true)
        state.activityChanged(count: 2)
        state.dismiss()
        state.restore(expanded: false)
        #expect(state.mode == .compact)
        #expect(!state.dismissed)
        state.toggle()
        #expect(state.mode == .expanded)
        state.dismiss()
        state.restore()
        #expect(state.mode == .expanded)
        state.configure(enabled: false, available: true)
        state.restore(expanded: false)
        #expect(state.mode == .absent)
    }

    @Test func individualCompletionKeepsRemainingAgentAndDoesNotInventTaskSuccess() {
        let model = IslandPresentation()
        model.lifecycle.configure(enabled: true, available: true)
        func snapshot(_ states: [(String, AgentActivity)]) -> AgentSnapshot {
            AgentSnapshot(statuses: [AgentStatus(kind: .codex, state: .working, runningProcessCount: states.count,
                sessions: states.map { id, state in
                    AgentSessionActivity(id: id, kind: .codex, state: state, updatedAt: .now,
                        projectName: "demo", processID: 1, source: .hook, sessionTitle: "Task " + id)
                })])
        }
        model.receive(snapshot([("a", .working), ("b", .working)]))
        #expect(model.completions.isEmpty)
        model.receive(snapshot([("a", .idle), ("b", .working)]))
        #expect(model.lifecycle.workingCount == 1)
        #expect(model.completions.first?.row.sessionTitle == "Task a")
        #expect(model.completions.first?.closed == false)
        model.receive(snapshot([]))
        #expect(model.lifecycle.workingCount == 0)
        #expect(model.completions.first?.label == "Сессия закрыта")
        model.receive(snapshot([("b", .working)]))
        #expect(!model.completions.contains { $0.id == "codex:b" })
    }

    @Test func sleepIndicatorFollowsActualProtectionNotTheAgentCount() {
        let off = IslandSleepState(agentMode: true)
        #expect(!off.preventsSleep)
        #expect(off.title == "drem не мешает Mac уснуть")
        let lid = IslandSleepState(active: true, clamshell: true)
        #expect(lid.title.contains("закрытой"))
        let open = IslandSleepState(active: true)
        #expect(open.title.contains("открытой"))
        let paused = IslandSleepState(active: true, paused: true)
        #expect(!paused.preventsSleep)
        #expect(paused.title.contains("паузе"))
        var state = IslandLifecycle()
        state.configure(enabled: true, available: true)
        state.wakeChanged(true)
        #expect(state.mode == .compact, "Manual blocking is visible without working agents")
        state.wakeChanged(false)
        #expect(state.mode == .absent)
    }

    @Test func folderIdentityGroupsItsAgentsAndKeepsDifferentFoldersDistinct() {
        let a = IslandRow(id: "codex:aaaaaa", kind: .codex, project: "demo", action: "Работает",
            status: nil, directory: "/tmp/demo", sessionTitle: "Saved session name")
        let b = IslandRow(id: "claude:bbbbbb", kind: .claude, project: "demo", action: "Читает",
            status: nil, directory: "/tmp/demo")
        let sameSession = IslandRow(id: a.id, kind: .codex, project: "demo", action: "Использует инструмент",
            status: "Другой публичный текст", directory: "/tmp/demo")
        #expect(a.avatarSeed == b.avatarSeed,
            "Provider and session ID must not split agents that work in one folder")
        #expect(IslandBlobIdentity(seed: a.avatarSeed) == IslandBlobIdentity(seed: b.avatarSeed))
        #expect(a.avatarSeed == sameSession.avatarSeed,
            "Activity and public text must not change a folder's avatar")

        let cliproxy = IslandRow(id: "codex:one", kind: .codex, project: "cliproxyapi_manager",
            action: "Работает", status: nil, directory: "/Users/mrvasil/work/cliproxyapi_manager")
        let federation = IslandRow(id: "codex:one", kind: .codex, project: "federation_cup",
            action: "Работает", status: nil, directory: "/Users/mrvasil/Desktop/Alexey/CTF/federation_cup")
        #expect(cliproxy.avatarSeed != federation.avatarSeed)
        #expect(cliproxy.colorIndex != federation.colorIndex,
            "Different folders must not collapse into the same seven-colour bucket")
        #expect(a.name(showStatus: true) == "demo · Saved session name")
        #expect(a.sessionName(showStatus: true) == "Saved session name")
        #expect(a.name(showStatus: false) == "demo")
        #expect(a.sessionName(showStatus: false) == nil)
        #expect(b.name(showStatus: true) == "demo")
    }

    @Test func blobIdentityIsStableVariedAndAlwaysFitsItsCanvas() {
        let first = IslandBlobIdentity(seed: 0x1234_5678)
        #expect(first == IslandBlobIdentity(seed: 0x1234_5678))
        let identities = (0..<64).map { IslandBlobIdentity(seed: UInt64($0)) }
        #expect(Set(identities.map(\.colorIndex)).count == identities.count)
        #expect(Set(identities.map(\.silhouette)).count == IslandBlobSilhouette.allCases.count)
        #expect(Set(identities.map(\.eyeSpacing)).count > 1)
        for silhouette in IslandBlobSilhouette.allCases {
            let bounds = IslandBlobGeometry.path(silhouette).boundingBoxOfPath
            #expect(bounds.minX >= 0 && bounds.minY >= 0)
            #expect(bounds.maxX <= 100 && bounds.maxY <= 100)
            #expect(bounds.width >= 70 && bounds.height >= 55)
        }
    }

    @Test func savedSessionNamesSupplementFoldersWithoutDuplicatingOrHidingThem() {
        var row = IslandRow(id: "codex:123456", kind: .codex, project: "drem", action: "Работает", status: nil)
        for title: String? in [nil, "", "  ", "drem", "DREM", " drem "] {
            row.sessionTitle = title
            #expect(row.sessionName(showStatus: true) == nil)
            #expect(row.name(showStatus: true) == "drem")
        }
        row.sessionTitle = "  Новый островок  "
        #expect(row.sessionName(showStatus: true) == "Новый островок")
        #expect(row.name(showStatus: true) == "drem · Новый островок")
        #expect(row.project == "drem")
        #expect(row.name(showStatus: false) == "drem")
    }

    @Test func transparentCornersDoNotCatchClicks() {
        let rect = CGRect(x: 100, y: 600, width: 420, height: 200)
        #expect(IslandHitRegion.contains(CGPoint(x: 310, y: 700), rect: rect, expanded: true))
        #expect(!IslandHitRegion.contains(CGPoint(x: 101, y: 601), rect: rect, expanded: true))
        #expect(!IslandHitRegion.contains(CGPoint(x: 99, y: 700), rect: rect, expanded: true))
        #expect(IslandHitRegion.contains(CGPoint(x: 101, y: 799), rect: rect, expanded: true), "Top left is square")
        #expect(IslandHitRegion.contains(CGPoint(x: 519, y: 799), rect: rect, expanded: true), "Top right is square")
        let drawPath = IslandOutline.path(in: CGRect(origin: .zero, size: rect.size), radius: 26, flipped: true)
        for x in stride(from: CGFloat(0.5), through: rect.width, by: 5) {
            for y in stride(from: CGFloat(0.5), through: rect.height, by: 5) {
                #expect(drawPath.contains(CGPoint(x: x, y: y)) == IslandHitRegion.contains(
                    CGPoint(x: rect.minX + x, y: rect.maxY - y), rect: rect, expanded: true))
            }
        }
    }

    @Test func swipesRejectWrongVerticalDirectionMomentumWheelsAndOffTargetStarts() {
        for inverted in [false, true] {
            for intent: IslandSwipe.Intent in [.hide, .restore] {
                var swipe = IslandSwipe()
                let wrong: CGFloat = (inverted ? -100 : 100) * (intent == .hide ? -1 : 1)
                #expect(swipe.consume(x: 2, y: wrong, inverted: inverted, precise: true,
                    timestamp: 1, phase: .began, momentum: false, intent: intent).feedback?.progress == 0)
                #expect(swipe.finish(at: 1.1).resolution == .cancel)
                #expect(swipe.consume(x: 100, y: 0, inverted: inverted, precise: true,
                    timestamp: 2, phase: .began, momentum: true, intent: intent).captured == false)
                #expect(swipe.consume(x: 100, y: 0, inverted: inverted, precise: false,
                    timestamp: 3, phase: .began, momentum: false, intent: intent).captured == false)
                #expect(swipe.consume(x: 100, y: 0, inverted: inverted, precise: true,
                    timestamp: 4, phase: .began, momentum: false, intent: nil).captured == false)
                #expect(swipe.consume(x: 100, y: 0, inverted: inverted, precise: true,
                    timestamp: 4.1, phase: .changed, momentum: false, intent: intent).captured == false)
                #expect(swipe.consume(x: 50, y: 0, inverted: inverted, precise: true,
                    timestamp: 5, phase: .began, momentum: false, intent: intent).feedback?.ready == true)
                #expect(swipe.finish(at: 5.1).resolution == .commit(intent))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_ISLAND_RENDER_DIRECTORY"] != nil))
    func renderReviewFixtures() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["DREM_ISLAND_RENDER_DIRECTORY"])
        let model = IslandPresentation()
        model.notchWidth = 185
        model.notchHeight = 32
        model.isPresented = true
        model.reduceMotion = true
        model.sleep = IslandSleepState(active: true, clamshell: true, agentMode: true)
        model.rows = [
            IslandRow(id: "one", kind: .codex, project: "drem", action: "Редактирует файл · IslandView.swift", status: "Добавляю плавное раскрытие и проверяю поведение окна.", headline: "Refining the notch", activity: .editing, sessionTitle: "Новый островок drem"),
            IslandRow(id: "two", kind: .claude, project: "website", action: "Читает файл · README.md", status: "Проверяю структуру проекта перед изменениями.", activity: .reading, sessionTitle: "Страница настроек")
        ]
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 2)
        for name in ["compact", "preview", "expanded", "detail", "private", "actions", "compacting", "attention", "attention-detail", "attention-private", "attention-compact", "many", "completed"] {
            if name == "preview" { model.lifecycle.hover(true) }
            if name == "expanded" { model.lifecycle.toggle() }
            if name == "detail" { model.select("one") }
            if name == "private" { model.showPublicStatus = false }
            if name == "actions" {
                model.showPublicStatus = true
                model.showOverview()
                let actions: [AgentActivityDetail.Action] = [.working, .reading, .editing, .tool, .compacting]
                model.replaceRows(actions.enumerated().map { index, action in
                    IslandRow(id: "action-\(index)", kind: index % 2 == 0 ? .codex : .claude,
                        project: "project-\(index)", action: action.title, status: nil, activity: action)
                })
                model.lifecycle.activityChanged(count: actions.count)
            }
            if name == "compacting" { model.hoveredID = "action-4" }
            if name == "attention" {
                model.replaceRows([
                    IslandRow(id: "one", kind: .codex, project: "drem", action: "Работает", status: nil),
                    IslandRow(id: "two", kind: .claude, project: "website", action: "Использует инструмент", status: nil,
                        sessionTitle: "Обновление главной страницы", attention: .permission),
                    IslandRow(id: "three", kind: .claude, project: "docs", action: "Использует инструмент", status: nil,
                        attention: .question)
                ])
                model.lifecycle.activityChanged(count: 3)
            }
            if name == "attention-detail" { model.select("two") }
            if name == "attention-private" { model.showPublicStatus = false }
            if name == "attention-compact" { model.lifecycle.collapse() }
            if name == "many" {
                model.showPublicStatus = true
                model.showOverview()
                model.lifecycle.restore()
                model.replaceRows((0..<12).map {
                    IslandRow(id: "session-\($0)", kind: $0 % 2 == 0 ? .codex : .claude,
                        project: "a-long-project-name-\($0)", action: "Редактирует файл · IslandView.swift", status: nil, activity: .editing)
                })
                model.lifecycle.activityChanged(count: 12)
            }
            if name == "completed" { model.lifecycle.activityChanged(count: 0) }
            let host = NSHostingView(rootView: IslandView(model: model, toggle: {}, hide: {}))
            let size = NSSize(width: model.expandedWidth + 40, height: model.canvasHeight + 24)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name).png"))
            window.contentView = nil
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_ISLAND_MOTION_DIRECTORY"] != nil))
    func renderMotionReview() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["DREM_ISLAND_MOTION_DIRECTORY"])
        let model = IslandPresentation()
        model.isPresented = true
        model.rows = [
            IslandRow(id: "one", kind: .codex, project: "drem", action: "Редактирует · IslandView.swift",
                status: "Проверяю анимацию раскрытия, переключение агентов и кликабельность.",
                headline: "Refining the notch animation", directory: "/tmp", activity: .editing),
            IslandRow(id: "two", kind: .claude, project: "website", action: "Читает · README.md", status: "Проверяю структуру проекта.", activity: .reading)
        ]
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 2)
        let size = NSSize(width: model.expandedWidth + 40, height: model.canvasHeight + 24)
        let host = NSHostingView(rootView: IslandView(model: model, toggle: {}, hide: {}))
        let window = NSPanel(contentRect: NSRect(origin: CGPoint(x: -3000, y: -3000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        var captures: [Data] = []
        var times: [String] = ["frame,elapsed_seconds"]
        for frame in 0..<66 {
            try await Task.sleep(until: start.advanced(by: .milliseconds(frame * 33)), clock: .continuous)
            if frame == 4 { model.lifecycle.toggle() }
            if frame == 23 { model.select("one") }
            if frame == 36 { model.select("two"); model.pointer = 0.8 }
            if frame == 49 { model.lifecycle.collapse() }
            // Let SwiftUI commit this event before sampling; no fixed extra frame delay.
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            captures.append(data)
            let elapsed = start.duration(to: .now).components
            times.append("\(frame),\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)")
        }
        for (frame, data) in captures.enumerated() {
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(String(format: "frame-%03d.png", frame)))
        }
        try times.joined(separator: "\n").write(to: URL(fileURLWithPath: destination).appendingPathComponent("sample-times.csv"), atomically: true, encoding: .utf8)
    }

    @Test func creatureMotionStopsForReducedMotionAndRemoval() {
        let robot = IslandRobotView()
        func animationCount(_ layer: CALayer?) -> Int {
            (layer?.animationKeys()?.count ?? 0) + (layer?.sublayers ?? []).reduce(0) { $0 + animationCount($1) }
        }
        robot.configure(kind: .codex, action: .editing, pointer: 1, animated: true, celebrating: false)
        #expect(animationCount(robot.layer) >= 3)
        robot.configure(kind: .codex, action: .editing, pointer: 1, animated: false, celebrating: false)
        #expect(animationCount(robot.layer) == 0)
        robot.configure(kind: .claude, action: .reading, pointer: -1, animated: true, celebrating: false)
        #expect(animationCount(robot.layer) >= 2)
        robot.stopMotion()
        #expect(animationCount(robot.layer) == 0)
    }

    @Test func waitingCreatureDoesNotSimulateWorkAndAttentionReactionIsFinite() {
        let robot = IslandRobotView()
        func animations(_ layer: CALayer?) -> [(String, CAAnimation)] {
            let own = (layer?.animationKeys() ?? []).compactMap { key in layer?.animation(forKey: key).map { (key, $0) } }
            return own + (layer?.sublayers ?? []).flatMap { animations($0) }
        }
        robot.configure(kind: .claude, action: .tool, pointer: 0, animated: true,
            celebrating: false, needsAttention: true)
        #expect(!animations(robot.layer).contains { $0.0 == "focus" })
        #expect(animations(robot.layer).contains { $0.0 == "attention" && $0.1.repeatCount == 0 })
        robot.configure(kind: .claude, action: .tool, pointer: 0, animated: true,
            celebrating: false, needsAttention: false)
        #expect(animations(robot.layer).contains { $0.0 == "focus" })
        robot.configure(kind: .claude, action: .tool, pointer: 0, animated: false,
            celebrating: false, needsAttention: true)
        #expect(animations(robot.layer).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_ISLAND_PERFORMANCE"] == "1"))
    func measureVisibleAnimationCost() async throws {
        let model = IslandPresentation()
        model.isPresented = true
        model.rows = [IslandRow(id: "fixture", kind: .codex, project: "Design review",
            action: "Тестовая панель анимации", status: nil, activity: .tool)]
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 1)
        let size = NSSize(width: model.expandedWidth + 40, height: model.canvasHeight + 24)
        let window = NSPanel(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear; window.isOpaque = false; window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: IslandView(model: model, toggle: {}, hide: {}))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        for mode in ["compact", "expanded", "expanded-steady", "reduced", "removed"] {
            if mode == "expanded" { model.lifecycle.toggle() }
            if mode == "reduced" { model.reduceMotion = true }
            if mode == "removed" { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(700))
            let start = Date()
            let cpu = cpuSeconds()
            try await Task.sleep(for: .seconds(3))
            let percent = (cpuSeconds() - cpu) / Date().timeIntervalSince(start) * 100
            print("ISLAND_CPU_\(mode)=\(String(format: "%.2f", percent))%")
        }
    }

    @Test func hiddenLatchSurvivesAdditionalAgentsAndScreenChanges() {
        var state = IslandLifecycle()
        state.configure(enabled: true, available: true)
        state.activityChanged(count: 1)
        #expect(state.mode == .compact)
        state.hover(true)
        #expect(state.mode == .preview)
        state.toggle()
        state.hover(false)
        #expect(state.mode == .expanded)
        state.dismiss()
        state.activityChanged(count: 2)
        state.configure(enabled: true, available: false)
        state.configure(enabled: true, available: true)
        #expect(state.mode == .absent)
        state.activityChanged(count: 0)
        #expect(state.mode == .absent)
        state.activityChanged(count: 1)
        #expect(state.mode == .compact)
    }

    @Test func dismissalFromManualWakeCannotHideTheNextAgentCycle() {
        var state = IslandLifecycle()
        state.configure(enabled: true, available: true)
        state.wakeChanged(true)
        state.dismiss()
        state.wakeChanged(false)
        #expect(!state.dismissed, "Ending the only reason to show the island ends its dismissal cycle")
        state.activityChanged(count: 1)
        #expect(state.mode == .compact)
    }

    @Test func completionIsVisualAndCannotDelayTheZeroCount() {
        var state = IslandLifecycle()
        state.configure(enabled: true, available: true)
        state.activityChanged(count: 2)
        state.activityChanged(count: 1)
        #expect(state.mode == .compact)
        state.activityChanged(count: 0)
        #expect(state.mode == .completed)
        #expect(state.workingCount == 0)
        state.activityChanged(count: 1)
        state.finishCompletion()
        #expect(state.mode == .compact, "A stale completion callback cannot hide new work")
    }

    @Test func unavailableOrDisabledNeverShowsEvenAfterManualRestore() {
        var state = IslandLifecycle()
        state.activityChanged(count: 1)
        state.restore()
        #expect(state.mode == .absent)
        state.configure(enabled: true, available: false)
        state.restore()
        #expect(state.mode == .absent)
        state.configure(enabled: true, available: true)
        #expect(state.mode == .compact)
        state.dismiss()
        state.restore()
        #expect(state.mode == .expanded)
        state.configure(enabled: false, available: true)
        #expect(state.mode == .absent)
    }

    @Test func timestampOnlyUpdatesAndInputOrderingDoNotChangeRows() {
        func snapshot(_ time: Date, reverse: Bool) -> AgentSnapshot {
            let sessions = ["a", "b"].map {
                AgentSessionActivity(id: $0, kind: .codex, state: .working, updatedAt: time,
                    projectName: "same-project", processID: 1, source: .transcript,
                    detail: AgentActivityDetail(publicStatus: "Проверяю", confirmedAt: time))
            }
            return AgentSnapshot(statuses: [.init(kind: .codex, state: .working,
                runningProcessCount: 2, sessions: reverse ? sessions.reversed() : sessions)])
        }
        let rows = IslandRow.rows(snapshot(.distantPast, reverse: false))
        #expect(rows == IslandRow.rows(snapshot(.distantFuture, reverse: true)))
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test func dimensionsKeepContentBelowPhysicalNotchAndStayShallow() {
        let model = IslandPresentation()
        model.notchWidth = 185
        model.notchHeight = 32
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 10)
        model.lifecycle.toggle()
        model.rows = (0..<10).map { IslandRow(id: "\($0)", kind: .codex, project: "demo", action: "Работает", status: nil) }
        #expect(model.width >= model.notchWidth + 92)
        #expect(model.height == CGFloat(248))
        model.showPublicStatus = false
        #expect(model.height == CGFloat(248))
        model.select("0")
        #expect(model.height == CGFloat(248))
        #expect(model.width == CGFloat(600))
    }

    @Test func selectionTracksIdentityNotPositionAndClearsWhenAgentEnds() {
        let model = IslandPresentation()
        let a = IslandRow(id: "a", kind: .codex, project: "same", action: "Работает", status: "Public")
        let b = IslandRow(id: "b", kind: .claude, project: "same", action: "Работает", status: nil)
        model.replaceRows([a, b])
        model.select("b")
        model.replaceRows([b, a])
        #expect(model.selectedRow == b)
        model.showOverview()
        #expect(model.featuredRow == b, "The character keeps its identity while collapsing")
        model.select("b")
        model.select("unknown")
        #expect(model.selectedRow == b)
        model.replaceRows([a])
        #expect(model.selectedRow == nil)
        #expect(model.featuredRow == a)
        model.replaceRows([])
        #expect(model.featuredRow == nil)
    }

    @Test func copyRespectsPrivacyAndProjectURLNeverUsesRemoteScheme() {
        var row = IslandRow(id: "codex:123456789", kind: .codex, project: "demo", action: "Работает",
                            status: "Public text", headline: "Public heading", directory: "/tmp/demo")
        #expect(row.copyText(showStatus: true).contains("Public text"))
        #expect(row.copyText(showStatus: false) == "Codex · demo\nРаботает")
        #expect(row.shortID == "456789")
        #expect(row.projectURL?.isFileURL == true)
        for invalid in ["https://example.com", "file:///tmp/demo", "relative/path", "", "/tmp/\0"] {
            row.directory = invalid
            #expect(row.projectURL == nil)
        }
    }
}

struct AgentDetailTests {
    @Test func codexUsesOnlyThePublicTUIHeadingNotTheSummaryBody() throws {
        let event = #"""
        {"timestamp":"2026-09-18T12:00:00Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"**Adding experimental_mode setting**\n\nPrivate summary body must not be displayed."}],"content":[{"type":"reasoning_text","text":"Raw reasoning must not be displayed"}]}}
        """#
        let detail = try #require(AgentDetailParser.consume(event, kind: .codex))
        #expect(detail.headline == "Adding experimental_mode setting")
        #expect(detail.publicStatus == nil)
        let encoded = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        #expect(!encoded.contains("Private summary"))
        #expect(!encoded.contains("Raw reasoning"))
        let tool = #"""
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}"}}
        """#
        #expect(AgentDetailParser.consume(tool, kind: .codex, previous: detail)?.headline == detail.headline)
        #expect(AgentDetailParser.consume("{\"type\":\"turn_context\"}", kind: .codex, previous: detail) == nil)
    }

    @Test func codexCompletedItemSupportsMultipleSummaryHeadingsButNotRawContent() {
        let event = #"""
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","summary_text":["**Inspecting files**\nprivate body","**Running checks**\nprivate body"],"raw_content":["**Not a public title**"]}}}
        """#
        #expect(AgentDetailParser.consume(event, kind: .codex)?.headline == "Running checks")
        let plain = #"""
        {"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"A paragraph without an explicit UI heading."}]}}
        """#
        #expect(AgentDetailParser.consume(plain, kind: .codex)?.headline == nil)
    }

    @Test func exactBoundProcessSuppliesRenamedProjectForPresentation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Project-\(UUID())")
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = directory.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"one","cwd":"/tmp/old-name"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: log)
        let process = DetectedAgentProcess(id: 303, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
            workingDirectory: "/tmp/new-name", openTranscriptPaths: [log.path])
        let engine = LiveActivityEngine(homeDirectory: home)
        let result = await engine.reconcile(processes: [process])
        #expect(result.snapshot.status(for: .codex).workingSessions.first?.projectName == "new-name")
        #expect(result.snapshot.status(for: .codex).workingSessions.first?.workingDirectory == "/tmp/new-name")
        #expect(result.snapshot.workingCount == 1)
    }

    @Test func codexIgnoresReasoningUserTextAndToolOutputs() throws {
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"private request"}]}}
        {"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"private reasoning"}]}}
        {"timestamp":"2026-09-18T12:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Проверяю тесты"}]}}
        {"type":"response_item","payload":{"type":"function_call","name":"functions.exec_command","arguments":"{\"cmd\":\"secret-command\"}"}}
        {"type":"response_item","payload":{"type":"function_call_output","output":"private output"}}
        """#
        let detail = try #require(AgentDetailParser.consume(text, kind: .codex))
        #expect(detail.publicStatus == "Проверяю тесты")
        #expect(detail.action == .working)
        #expect(detail.fileName == nil)
        let encoded = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        #expect(!encoded.contains("private"))
        #expect(!encoded.contains("secret-command"))
    }

    @Test func claudeExtractsOnlyPublicTextAndSafeBasename() throws {
        let text = """
        {"timestamp":"2026-09-18T12:00:00Z","type":"assistant","message":{"content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"Исправляю окно"},{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/private/project/Window.swift","old_string":"secret body"}}],"stop_reason":"tool_use"}}
        """
        let detail = try #require(AgentDetailParser.consume(text, kind: .claude))
        #expect(detail.publicStatus == "Исправляю окно")
        #expect(detail.fileName == "Window.swift")
        #expect(detail.action == .editing)
        #expect(detail.confirmedAt != nil)
        let final = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Готово"}],"stop_reason":"end_turn"}}
        """
        #expect(AgentDetailParser.consume(final, kind: .claude, previous: detail) == nil)
    }

    @Test func boundariesResetDetailsAndUnknownToolsNeverInventActions() {
        let previous = AgentActivityDetail(action: .editing, fileName: "Old.swift", publicStatus: "Old")
        #expect(AgentDetailParser.consume("{\"type\":\"turn_context\"}", kind: .codex, previous: previous) == nil)
        let tool = """
        {"type":"response_item","payload":{"type":"function_call","name":"unknown","arguments":{"command":"swift test","path":"/private/Secret"}}}
        """
        let detail = AgentDetailParser.consume(tool, kind: .codex)
        #expect(detail?.action == .tool)
        #expect(detail?.fileName == nil)
        #expect(AgentDetailParser.consume("{broken", kind: .codex, previous: previous) == previous)
    }

    @Test func oldSessionJSONStillDecodes() throws {
        let session = AgentSessionActivity(id: "old", kind: .codex, state: .working,
            updatedAt: .distantPast, projectName: "demo", processID: 1, source: .hook)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "detail")
        let decoded = try JSONDecoder().decode(AgentSessionActivity.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == session)
    }

    @Test func incrementalPartialJSONPreservesDetailWithoutChangingActivity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Island-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("log.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"one","cwd":"/tmp/demo"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: file)
        let scanner = IncrementalTranscriptScanner()
        #expect(scanner.consume(url: file, kind: .codex)?.session.state == .working)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Checking".utf8))
        #expect(scanner.consume(url: file, kind: .codex)?.session.detail == nil)
        try handle.write(contentsOf: Data(" tests\"}]}}\n".utf8))
        let result = try #require(scanner.consume(url: file, kind: .codex))
        #expect(result.session.detail?.publicStatus == "Checking tests")
        #expect(result.session.state == .working)
        #expect(scanner.consume(url: file, kind: .codex)?.bytesRead == 0)
        #expect(scanner.consume(url: file, kind: .codex)?.session.detail == result.session.detail)
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8))
        #expect(scanner.consume(url: file, kind: .codex)?.session.detail == nil)
        #expect(scanner.consume(url: file, kind: .codex)?.session.state == .idle)
    }

    @Test func detailsSurviveHookTieButNotNewTurnAndNeverChangeGoalPolicy() {
        let date = Date(timeIntervalSince1970: 100)
        func session(source: ActivitySource, at: Date, detail: AgentActivityDetail?) -> AgentSessionActivity {
            AgentSessionActivity(id: "one", kind: .codex, state: .working, updatedAt: at,
                projectName: "demo", processID: 1, source: source, detail: detail)
        }
        let detail = AgentActivityDetail(publicStatus: "Checking", confirmedAt: date)
        let transcript = session(source: .transcript, at: date, detail: detail)
        let hook = session(source: .hook, at: date, detail: nil)
        let merged = AgentActivityEvidence.merge(hooks: [hook], transcripts: [transcript])
        #expect(merged.first?.source == .hook)
        #expect(merged.first?.detail == detail)
        let newHook = session(source: .hook, at: date.addingTimeInterval(1), detail: nil)
        #expect(AgentActivityEvidence.merge(hooks: [newHook], transcripts: [transcript]).first?.detail == nil)
        let goal = AgentActivityEvidence.applyingActiveCodexGoals(merged, activeGoals: ["one": date])
        #expect(goal.first?.source == .goal)
        #expect(goal.first?.detail == detail)
    }
}
