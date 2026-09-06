// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import DremCore
import SwiftUI

struct KeepAwakeControls: View {
    @ObservedObject var awake: KeepAwakeManager
    @AppStorage(KeepAwakeDefaultsKey.defaultDuration) private var duration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { awake.isActive },
                set: { enabled in
                    if enabled { awake.activate(minutes: duration) }
                    else if awake.isActive { awake.toggle() }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Не давать Mac уснуть")
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Не давать Mac уснуть")
            .accessibilityHint(status)
            .disabled(awake.whileAgentsWork && !awake.hasWorkingAgent && !awake.isActive)
            Toggle(isOn: $awake.whileAgentsWork) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Пока работают агенты")
                    Text(agentStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Пока работают агенты")
            .accessibilityHint("Только во время задач, включая закрытую крышку. После последней задачи drem снимает все свои блокировки сна.")
            .disabled(awake.clamshellSetupInProgress)
            if awake.isActive, awake.endDate != nil {
                HStack {
                    Text("Продлить").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("+\(minutes) мин") { awake.extend(minutes: minutes) }
                            .buttonStyle(.borderless)
                    }
                }.font(.system(size: 11))
            }
            if let error = awake.lastError ?? awake.brightnessError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.small)
    }
    private var status: String {
        if awake.isPausedForScreenLock { return "Пауза до разблокировки" }
        guard awake.isActive else { return "Обычный режим сна" }
        if let end = awake.endDate {
            return "До \(end.formatted(date: .omitted, time: .shortened))"
        }
        if awake.sessionTrigger == .automation {
            if awake.activeAutomationConditions.contains(.agents) { return "Агенты выполняют задачи" }
            if awake.activeAutomationConditions == [.power] { return "Подключено питание" }
            if awake.activeAutomationConditions == [.externalDisplay] { return "Подключён внешний дисплей" }
            return "По условиям автоматизации"
        }
        return "До выключения вручную"
    }
    private var agentStatus: String {
        if awake.clamshellSetupInProgress { return "Настройка разрешения…" }
        if awake.clamshellSetupFailed { return "Не настроено — откройте настройки" }
        if awake.whileAgentsWork, awake.hasWorkingAgent {
            if !awake.isActive || !awake.agentRequiresWake { return "Удержание сна приостановлено" }
            if awake.clamshellActive { return "Можно закрыть крышку" }
            return "Включается защита сна крышки…"
        }
        if awake.whileAgentsWork { return "Нет активных задач — сон разрешён" }
        return "Включая закрытую крышку"
    }
}

struct KeepAwakeSettings: View {
    @ObservedObject var awake: KeepAwakeManager
    @ObservedObject private var hotkey = KeepAwakeHotkeyManager.shared
    @AppStorage(KeepAwakeDefaultsKey.defaultDuration) private var duration = 0
    @AppStorage(KeepAwakeDefaultsKey.batteryLimit) private var battery = 10
    @AppStorage(KeepAwakeDefaultsKey.autoStart) private var autoStart = false
    @AppStorage(KeepAwakeDefaultsKey.rightClickToggle) private var rightClick = false
    @AppStorage(KeepAwakeDefaultsKey.allowDisplaySleep) private var displaySleep = false
    @AppStorage(KeepAwakeDefaultsKey.externalDisplay) private var externalDisplay = false
    @AppStorage(KeepAwakeDefaultsKey.connectedToPower) private var power = false
    @AppStorage(KeepAwakeDefaultsKey.pauseWhenLocked) private var pauseLocked = false
    @AppStorage(KeepAwakeDefaultsKey.mouseJiggleEnabled) private var jiggle = false
    @AppStorage(KeepAwakeDefaultsKey.mouseJiggleInterval) private var jiggleInterval = 5
    @AppStorage(KeepAwakeDefaultsKey.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(KeepAwakeDefaultsKey.iconTint) private var iconTint = KeepAwakeIconTint.none.rawValue
    @AppStorage(KeepAwakeDefaultsKey.activeIcon) private var activeIcon = KeepAwakeActiveIcon.drem.rawValue
    @AppStorage(KeepAwakeDefaultsKey.showCountdown) private var showCountdown = false

    var body: some View {
        TabView {
            sleepSettings.tabItem { Label("Сон", systemImage: "moon") }
            controlSettings.tabItem { Label("Управление", systemImage: "slider.horizontal.3") }
            appearanceSettings.tabItem { Label("Оформление", systemImage: "paintbrush") }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .onAppear { awake.refreshAccessibilityStatus() }
        .onDisappear { if hotkey.isCapturing { hotkey.cancelCapture() } }
    }
    private var sleepSettings: some View {
        Form {
            Section("Ручной режим") {
                Picker("Длительность", selection: $duration) {
                    Text("15 минут").tag(15)
                    Text("30 минут").tag(30)
                    Text("1 час").tag(60)
                    Text("2 часа").tag(120)
                    Text("4 часа").tag(240)
                    Text("8 часов").tag(480)
                    Text("Бессрочно").tag(0)
                }
                Toggle("Разрешать дисплею выключаться", isOn: $displaySleep)
                Toggle("Включать при запуске drem", isOn: $autoStart)
                Picker("Отключать при заряде", selection: $battery) {
                    Text("Никогда").tag(0)
                    ForEach([5, 10, 15, 20], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Section {
                Toggle("Пока работают агенты", isOn: $awake.whileAgentsWork)
                    .disabled(awake.clamshellSetupInProgress)
                Toggle("При подключённом питании", isOn: $power)
                    .onChange(of: power) { _ in awake.automationPreferencesDidChange() }
                    .disabled(awake.whileAgentsWork)
                Toggle("С внешним дисплеем", isOn: $externalDisplay)
                    .onChange(of: externalDisplay) { _ in awake.automationPreferencesDidChange() }
                    .disabled(awake.whileAgentsWork)
                Toggle("Пауза при блокировке Mac", isOn: $pauseLocked)
            } header: { Text("Автоматическое включение") } footer: {
                Text("Режим агентов имеет приоритет: после последней задачи снимаются все блокировки сна. При закрытии крышки встроенный экран затемняется, при открытии прежняя яркость возвращается. Остальные режимы доступны, когда режим агентов выключен.")
            }
            Section {
                Toggle("Не спать с закрытой крышкой", isOn: $awake.clamshellPreferred)
                    .disabled(awake.clamshellSetupInProgress)
                if awake.clamshellRulePresent, !awake.clamshellActive {
                    Button("Удалить системное разрешение…") { awake.removeClamshellPermission() }
                        .disabled(awake.clamshellSetupInProgress)
                }
            } header: { Text("Крышка в остальных режимах") } footer: { Text(clamshellCaption) }
            if let error = awake.lastError ?? awake.brightnessError { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped)
    }
    private var controlSettings: some View {
        Form {
            Section("Строка меню") {
                Toggle("Правый клик переключает режим сна", isOn: $rightClick)
                Toggle("Показывать оставшееся время", isOn: $showCountdown)
            }
            Section("Горячая клавиша") {
                Toggle("Включить сочетание клавиш", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { hotkey.setEnabled($0) }
                if hotkeyEnabled {
                    LabeledContent("Переключить режим") {
                        Button(hotkey.isCapturing ? "Нажмите сочетание…" : hotkey.shortcut.displayString) { hotkey.beginCapture() }
                        Button { hotkey.resetToDefault() } label: { Image(systemName: "arrow.uturn.backward") }
                            .help("Вернуть ⌃⌥⌘K")
                            .accessibilityLabel("Сбросить сочетание клавиш")
                    }
                    if let error = hotkey.captureError { Text(error).foregroundStyle(.red) }
                    else if hotkey.registrationFailed { Text("Сочетание занято другим приложением").foregroundStyle(.red) }
                }
            }
            Section {
                Toggle("Слегка двигать указатель", isOn: $jiggle)
                if jiggle {
                    Picker("Интервал", selection: $jiggleInterval) {
                        ForEach(KeepAwakePolicy.allowedMouseJiggleIntervals, id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    if !awake.accessibilityTrusted {
                        Button("Открыть Универсальный доступ…") { awake.requestAccessibility() }
                    }
                }
            } header: { Text("Указатель") } footer: {
                Text("Не требуется для удержания сна. Нужен только приложениям, отслеживающим движение мыши.")
            }
        }.formStyle(.grouped)
    }
    private var appearanceSettings: some View {
        Form {
            Section("Иконка при включённом блокировщике") {
                Picker("Символ", selection: $activeIcon) {
                    ForEach(KeepAwakeActiveIcon.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Цвет", selection: $iconTint) {
                    ForEach(KeepAwakeIconTint.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("«drem» — звезда. Когда блокировщик выключен, всегда показывается монохромная звезда. Работа агентов не переопределяет выбранные символ и цвет.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("drem", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Оформление следует настройкам macOS: светлая и тёмная тема, контрастность и уменьшение прозрачности.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var clamshellCaption: String {
        if awake.clamshellSetupInProgress { return "Настройка системного разрешения…" }
        if awake.clamshellSetupFailed { return "Не удалось настроить разрешение. Выключите и включите режим, чтобы повторить." }
        if awake.clamshellActive { return "Сон при закрытии крышки отключён до конца активного режима." }
        if awake.passwordlessClamshell { return "Системное разрешение настроено." }
        return "При первом включении macOS попросит пароль администратора."
    }
}
