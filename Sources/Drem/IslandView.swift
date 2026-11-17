import AppKit
import DremCore
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: IslandPresentation
    let toggle: () -> Void
    let hide: () -> Void
    var dragChanged: (CGSize) -> Void = { _ in }
    var dragEnded: (CGSize) -> Void = { _ in }
    @State private var copiedID: String?
    @State private var actionError: String?
    @State private var navigatingID: String?
    @State private var navigationTask: Task<Result<Void, TerminalNavigation.Failure>, Never>?

    private var expanded: Bool { model.lifecycle.mode == .expanded }
    private var featured: IslandRow? { model.featuredRow }
    private var featuredCompletion: IslandCompletion? {
        model.completions.first { $0.id == featured?.id }
    }
    private var accent: Color { featured.map(IslandPalette.color) ?? .cyan }
    private var gesture: IslandSwipe.Feedback? { model.reduceMotion ? nil : model.gesture }
    private var headerHelp: String {
        if let waiting = model.attentionRows.first {
            return waiting.name(showStatus: model.showPublicStatus) + " · " + waiting.title(showStatus: false)
        }
        if let done = model.completions.first { return done.row.name(showStatus: model.showPublicStatus) + " · " + done.label }
        return model.sleep.title
    }
    private var headerAccessibility: String {
        if expanded { return "Скрыть остров. Вернуть: свайп вбок или вниз над чёлкой" }
        return "drem. Работают сессии: \(model.lifecycle.workingCount). Нуждаются во внимании: \(model.attentionCount). \(model.sleep.title)"
    }
    private var secondary: Color { .white.opacity(model.increaseContrast ? 0.9 : 0.58) }
    private var motion: Animation {
        model.reduceMotion ? .easeOut(duration: 0.12)
            : .spring(response: expanded ? 0.42 : 0.34, dampingFraction: 0.84)
    }
    private var contentTransition: AnyTransition {
        model.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    header
                    if expanded {
                        expandedContent
                            .frame(width: model.expandedWidth - 24, height: 202, alignment: .top)
                            .fixedSize().padding(.top, 6).transition(contentTransition)
                    }
                }
                .frame(width: model.width, height: model.height, alignment: .top)
                // One character, one identity, carried from the notch into the card.
                Button {
                    model.react()
                    if !expanded { toggle() }
                } label: {
                    IslandRobot(kind: featured?.kind ?? .codex, action: featured?.activity ?? .working,
                            pointer: model.pointer, animated: model.isPresented && !model.reduceMotion,
                            celebrating: featuredCompletion != nil, colorIndex: featured?.colorIndex,
                            avatarSeed: featured?.avatarSeed,
                            pointerY: model.pointerY, reaction: model.reaction,
                            needsAttention: featured?.attention != nil)
                        .frame(width: expanded ? 94 : 27, height: expanded ? 116 : model.notchHeight - 2)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .position(x: expanded ? 65 : (model.width - model.notchWidth) / 4,
                              y: expanded ? model.notchHeight + 81 : model.notchHeight / 2)
                    .onHover { if $0 && expanded { model.react() } }
                    .help(expanded ? "Разбудить персонажа" : "Показать агентов")
                    .accessibilityLabel(expanded ? "Разбудить персонажа" : "Показать агентов")
            }
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(.black)
            .clipShape(IslandShell(radius: expanded ? 26 : 18))
            .overlay {
                IslandShell(radius: expanded ? 26 : 18)
                    .stroke(.white.opacity(expanded ? (model.increaseContrast ? 0.6 : 0.09) : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: expanded ? 15 : 0, y: expanded ? 5 : 0)
            .scaleEffect(x: gesture?.scaleX ?? 1, y: gesture?.scaleY ?? 1, anchor: .top)
            .offset(x: gesture?.offsetX ?? 0, y: gesture?.offsetY ?? 0)
            .opacity(Double(model.gesture?.opacity ?? 1))
            .scaleEffect(x: model.isPresented || model.reduceMotion ? 1 : 0.90,
                         y: model.isPresented || model.reduceMotion ? 1 : 0.65, anchor: .top)
            .opacity(model.isPresented ? 1 : 0)
            .animation(model.isPresented ? motion : .easeOut(duration: 0.22), value: model.isPresented)
            .animation(motion, value: model.lifecycle.mode)
            .animation(motion, value: model.selectedID)
            Spacer(minLength: 0)
        }
        .frame(width: model.expandedWidth + 40, height: model.canvasHeight + 24, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.selectedID) { _ in copiedID = nil; actionError = nil; navigationTask?.cancel() }
        .onDisappear { navigationTask?.cancel() }
        .onChange(of: model.lifecycle.mode) { mode in
            if mode != .expanded { model.showOverview(); actionError = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if expanded && model.selectedRow != nil { model.showOverview() } else { toggle() }
            } label: {
                Group {
                    if expanded {
                        HStack(spacing: 6) {
                            Image(systemName: model.selectedRow == nil ? "square.grid.2x2" : "chevron.left")
                            Text(model.selectedRow == nil ? "drem" : "Все агенты")
                        }.font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
                    } else { Color.clear }
                }
                .frame(maxWidth: .infinity).frame(height: model.notchHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded && model.selectedRow != nil ? "Все агенты" : "Показать агентов")
            Button(action: toggle) {
                Color.clear.frame(width: model.notchWidth + 4, height: model.notchHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Раскрыть или свернуть остров у камеры")
            Button {
                if expanded { hide() }
                else {
                    toggle()
                    if let waiting = model.attentionRows.first { model.select(waiting.id) }
                }
            } label: {
                HStack(spacing: 5) {
                    if expanded {
                        if model.attentionCount > 0 {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text("\(model.attentionCount) ждут").foregroundStyle(.orange).font(.system(size: 10))
                        } else {
                            Text("\(model.lifecycle.workingCount) в работе").font(.system(size: 10))
                        }
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                    } else {
                        if model.attentionCount > 0 {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        } else if !model.completions.isEmpty {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                        }
                        Text(String(model.lifecycle.workingCount)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        Image(systemName: model.sleep.symbol)
                            .foregroundStyle(model.sleep.preventsSleep ? Color.yellow : secondary)
                            .font(.system(size: 11, weight: .medium))
                    }
                }.foregroundStyle(secondary)
                    .frame(maxWidth: .infinity).frame(height: model.notchHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(headerHelp)
            .accessibilityLabel(Text(headerAccessibility))
        }
        .simultaneousGesture(DragGesture(minimumDistance: 4)
            .onChanged { dragChanged($0.translation) }
            .onEnded { dragEnded($0.translation) })
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    if let selected = model.selectedRow { detailCard(selected).transition(.opacity) }
                    else { overviewCard.transition(.opacity) }
                }.frame(width: model.selectedRow == nil ? 270 : model.expandedWidth - 78)
                ZStack {
                    if model.selectedRow != nil { agentRail.transition(.opacity) }
                    else { agentGrid.transition(.opacity) }
                }.frame(maxWidth: .infinity)
            }.frame(height: 164)
            HStack(spacing: 6) {
                Image(systemName: model.sleep.symbol).foregroundStyle(model.sleep.preventsSleep ? Color.yellow : secondary)
                Text(actionError ?? model.sleep.title)
                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: toggle) {
                    Image(systemName: "minus").font(.system(size: 10, weight: .medium))
                        .frame(width: 26, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(secondary).help("Свернуть остров").accessibilityLabel("Свернуть остров")
            }.padding(.horizontal, 6).help(actionError ?? model.sleep.detail)
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 96, height: 110)
                VStack(alignment: .leading, spacing: 5) {
                    Text(featured?.kind.displayName ?? "Агенты").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                    Text(featured?.project ?? "Агенты отдыхают")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let title = featured?.sessionName(showStatus: model.showPublicStatus) {
                        Text(title).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1).help(title)
                    }
                    Group {
                        if let done = featuredCompletion {
                            Label(done.label, systemImage: done.closed ? "stop.circle" : "checkmark.circle")
                        } else if let featured {
                            IslandActionLabel(action: featured.activity,
                                title: featured.title(showStatus: model.showPublicStatus), tint: accent, lineLimit: 2,
                                attention: featured.attention)
                                .foregroundStyle(featured.attention == nil ? secondary : .orange)
                                .help(featured.attention == nil ? featured.action : "Открой терминал агента, чтобы ответить")
                        } else {
                            Label(model.sleep.title, systemImage: model.sleep.symbol)
                        }
                    }.font(.system(size: 11)).foregroundStyle(secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 18).padding(.trailing, 14)
            }
            Spacer(minLength: 0)
            Button { if let featured { model.select(featured.id) } } label: {
                HStack {
                    Text(featured?.attention == nil ? "Подробнее о работе" : "Нужно твоё внимание")
                    Spacer()
                    Image(systemName: "arrow.right")
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 14).frame(height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(featured == nil)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground(accent: accent, featured: true, attention: featured?.attention != nil))
    }

    private var agentGrid: some View {
        ScrollView {
            if let done = model.completions.first {
                HStack(spacing: 7) {
                    Image(systemName: done.closed ? "stop.circle" : "checkmark.circle.fill").foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done.row.name(showStatus: model.showPublicStatus)).lineLimit(1)
                        Text(done.label + (model.completions.count > 1 ? " · ещё \(model.completions.count - 1)" : ""))
                            .foregroundStyle(secondary)
                    }.font(.system(size: 10))
                    Spacer(minLength: 0)
                }.padding(9).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: model.rows.count <= 2 ? 1 : 2), spacing: 6) {
                ForEach(model.rows) { row in
                    agentTile(row)
                }
            }.padding(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func agentTile(_ row: IslandRow) -> some View {
        Button { model.select(row.id) } label: { tileLabel(row) }
            .buttonStyle(IslandPressStyle(reduceMotion: model.reduceMotion))
            .onHover { inside in
                if inside { model.hoveredID = row.id }
                else if model.hoveredID == row.id { model.hoveredID = nil }
            }
            .help(row.name(showStatus: model.showPublicStatus) + "\n" + row.title(showStatus: model.showPublicStatus))
            .accessibilityLabel(Text("\(row.kind.displayName), \(row.name(showStatus: model.showPublicStatus)), сессия \(row.shortID)"))
            .accessibilityValue(Text(row.attention?.title ?? row.action))
            .accessibilityHint("Открыть статус и действия агента")
    }

    private func tileLabel(_ row: IslandRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                IslandAgentGlyph(kind: row.kind, size: 20, colorIndex: row.colorIndex, avatarSeed: row.avatarSeed)
                Text(row.kind == .codex ? "Codex" : "Claude").font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
                if let attention = row.attention {
                    Image(systemName: attention.islandSymbol).foregroundStyle(.orange)
                        .font(.system(size: 9)).accessibilityHidden(true)
                }
                Text("#" + row.shortID).font(.system(size: 8, design: .monospaced)).foregroundStyle(secondary)
            }.foregroundStyle(IslandPalette.color(row))
            Text(row.project).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94)).lineLimit(1).truncationMode(.middle)
            if let title = row.sessionName(showStatus: model.showPublicStatus) {
                Text(title).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
            }
            IslandActionLabel(action: row.activity, title: row.title(showStatus: model.showPublicStatus),
                tint: IslandPalette.color(row), fontSize: 9, attention: row.attention)
                .foregroundStyle(row.attention == nil ? secondary : .orange)
        }.padding(7).frame(maxWidth: .infinity, alignment: .leading).frame(height: 77)
            .background(cardBackground(accent: IslandPalette.color(row), featured: model.hoveredID == row.id,
                attention: row.attention != nil))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func detailCard(_ row: IslandRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                Color.clear.frame(width: 98, height: 120)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(row.kind.displayName).foregroundStyle(accent).font(.system(size: 10, weight: .medium))
                        Text(row.project)
                            .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let title = row.sessionName(showStatus: model.showPublicStatus) {
                            Text(title).font(.system(size: 11)).foregroundStyle(secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if row.attention == nil, model.showPublicStatus, let headline = row.headline {
                            Text(headline).font(.system(size: 11)).foregroundStyle(accent)
                        }
                        IslandActionLabel(action: row.activity, title: row.attention?.title ?? row.action, tint: accent,
                            fontSize: 10, lineLimit: nil, attention: row.attention)
                            .foregroundStyle(row.attention == nil ? accent : .orange)
                        if row.attention != nil {
                            Text("Ответь в терминале агента").font(.system(size: 10)).foregroundStyle(secondary)
                        } else if model.showPublicStatus, let status = row.status {
                            Text(status).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if row.attention == nil {
                            Text(row.sourceTitle + " · #" + row.shortID + (row.processID.map { " · PID \($0)" } ?? ""))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 13).padding(.bottom, 6)
                }.padding(.trailing, 14).frame(height: 122)
            }
            HStack(spacing: 8) {
                Button { openTerminal(row) } label: {
                    Label(navigatingID == row.id ? "Переход…" : "К агенту", systemImage: "terminal")
                        .frame(maxWidth: .infinity).frame(height: 28)
                }.disabled(row.processID == nil || row.processStartedAt == nil || navigatingID != nil)
                    .help("Перейти в точную вкладку Ghostty или iTerm2. macOS может запросить разрешение автоматизации")
                Button { reveal(row) } label: {
                    Label("Папка проекта", systemImage: "folder").frame(maxWidth: .infinity).frame(height: 28)
                }.disabled(row.projectURL == nil).help(row.directory ?? "Путь проекта ещё не определён")
                Button { copy(row) } label: {
                    Label(copiedID == row.id ? "Скопировано" : "Статус", systemImage: copiedID == row.id ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity).frame(height: 28)
                }.help("Скопировать отображаемый статус")
            }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                .foregroundStyle(accent).padding(.horizontal, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground(accent: accent, featured: true, attention: row.attention != nil))
    }

    private var agentRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(model.rows) { row in
                    railButton(row)
                }
            }
        }.padding(.vertical, 4).background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 14))
    }

    private func railButton(_ row: IslandRow) -> some View {
        let selected = row.id == model.selectedID
        return Button { model.select(row.id) } label: {
            IslandAgentGlyph(kind: row.kind, size: 25, colorIndex: row.colorIndex, avatarSeed: row.avatarSeed)
                .frame(width: 42, height: 42)
                .overlay(alignment: .topTrailing) {
                    if row.attention != nil {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(.orange).padding(2).accessibilityHidden(true)
                    }
                }
                .background(Color.white.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(IslandPalette.color(row)).frame(width: 2, height: 14) }
                }.contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(IslandPressStyle(reduceMotion: model.reduceMotion))
            .accessibilityLabel(Text("\(row.kind.displayName), \(row.name(showStatus: model.showPublicStatus)), сессия \(row.shortID)"))
            .accessibilityValue(Text([selected ? "Выбран" : nil, row.attention?.title].compactMap { $0 }.joined(separator: ". ")))
            .help(row.name(showStatus: model.showPublicStatus))
    }

    private func cardBackground(accent: Color, featured: Bool, attention: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(model.reduceTransparency ? Color(white: 0.12) : Color(white: 0.065))
            .overlay {
                if featured && !model.reduceTransparency {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, accent.opacity(0.10)], startPoint: .top, endPoint: .bottomLeading))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(attention ? Color.orange.opacity(model.increaseContrast ? 1 : 0.65)
                        : model.increaseContrast ? .white.opacity(0.65) : accent.opacity(featured ? 0.24 : 0.1),
                        lineWidth: attention ? 1 : 0.7)
            }
    }

    private func copy(_ row: IslandRow) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(row.copyText(showStatus: model.showPublicStatus), forType: .string) { copiedID = row.id }
        else { actionError = "Не удалось скопировать статус" }
    }

    private func openTerminal(_ row: IslandRow) {
        guard navigatingID == nil, let pid = row.processID, let startedAt = row.processStartedAt else { return }
        actionError = nil
        navigatingID = row.id
        let applications = TerminalNavigation.runningApplications()
        let task = Task.detached(priority: .userInitiated) {
            TerminalNavigation.open(pid: pid, startedAt: startedAt, applications: applications)
        }
        navigationTask = task
        Task { @MainActor in
            let result = await task.value
            navigatingID = nil
            navigationTask = nil
            guard !task.isCancelled, model.selectedID == row.id, model.lifecycle.mode == .expanded else { return }
            switch result {
            case .success: toggle()
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    private func reveal(_ row: IslandRow) {
        guard let url = row.projectURL else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            actionError = "Папка проекта больше не доступна"; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct IslandShell: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(IslandOutline.path(in: rect, radius: radius, flipped: true))
    }
}

private struct IslandPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
