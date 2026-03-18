//
//  StreamShortcuts.swift
//  Moonlight for macOS
//
//  Created by OpenAI Codex on 2026/03/18.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@objc enum StreamShortcutAction: Int, CaseIterable, Identifiable {
    case releaseMouse = 0
    case openControlCenter = 1
    case disconnectStream = 2
    case toggleConnectionDetails = 3
    case toggleMouseMode = 4
    case toggleFullscreenControlBall = 5
    case toggleBorderlessWindow = 6

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .releaseMouse:
            return "Release Mouse"
        case .openControlCenter:
            return "Open Control Center"
        case .disconnectStream:
            return "Disconnect Stream"
        case .toggleConnectionDetails:
            return "Toggle Connection Details"
        case .toggleMouseMode:
            return "Toggle Mouse Mode"
        case .toggleFullscreenControlBall:
            return "Toggle Fullscreen Control Ball"
        case .toggleBorderlessWindow:
            return "Toggle Borderless Window"
        }
    }

    fileprivate var storageKey: String {
        switch self {
        case .releaseMouse:
            return "releaseMouse"
        case .openControlCenter:
            return "openControlCenter"
        case .disconnectStream:
            return "disconnectStream"
        case .toggleConnectionDetails:
            return "toggleConnectionDetails"
        case .toggleMouseMode:
            return "toggleMouseMode"
        case .toggleFullscreenControlBall:
            return "toggleFullscreenControlBall"
        case .toggleBorderlessWindow:
            return "toggleBorderlessWindow"
        }
    }
}

struct StreamShortcutBinding: Codable, Hashable {
    static let allowedModifiers: NSEvent.ModifierFlags = [
        .shift, .control, .option, .command, .function,
    ]

    var keyCode: UInt16?
    var modifiersRawValue: UInt

    init(keyCode: UInt16?, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiersRawValue = Self.normalize(modifiers).rawValue
    }

    init(keyCode: UInt16?, modifiersRawValue: UInt) {
        self.keyCode = keyCode
        self.modifiersRawValue =
            Self.normalize(NSEvent.ModifierFlags(rawValue: modifiersRawValue))
            .rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    var isModifierOnly: Bool {
        keyCode == nil
    }

    var isValid: Bool {
        if isModifierOnly {
            return !modifiers.isEmpty
        }
        return true
    }

    func matches(keyEvent event: NSEvent) -> Bool {
        guard let keyCode else { return false }
        return keyCode == event.keyCode
            && modifiers == Self.normalize(event.modifierFlags)
    }

    func matches(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        isModifierOnly && modifiers == Self.normalize(modifierFlags)
            && !modifiers.isEmpty
    }

    static func normalize(_ flags: NSEvent.ModifierFlags)
        -> NSEvent.ModifierFlags
    {
        flags.intersection(allowedModifiers)
    }
}

private struct PersistedStreamShortcutBinding: Codable {
    var keyCode: UInt16?
    var modifiersRawValue: UInt
    var isEnabled: Bool

    init(binding: StreamShortcutBinding?) {
        if let binding {
            keyCode = binding.keyCode
            modifiersRawValue = binding.modifiersRawValue
            isEnabled = true
        } else {
            keyCode = nil
            modifiersRawValue = 0
            isEnabled = false
        }
    }

    var binding: StreamShortcutBinding? {
        guard isEnabled else { return nil }
        return StreamShortcutBinding(
            keyCode: keyCode,
            modifiersRawValue: modifiersRawValue
        )
    }
}

private enum StreamShortcutValidationError: Error {
    case duplicate(StreamShortcutAction)
    case reserved
}

private struct StreamShortcutKeyLabel {
    let display: String
    let menuEquivalent: String?
}

extension Array where Element == UniChar {
    fileprivate var stringValue: String {
        String(utf16CodeUnits: self, count: count)
    }
}

extension NSNotification.Name {
    static let streamShortcutsDidChange = NSNotification.Name(
        "StreamShortcutsDidChange"
    )
}

@objcMembers
final class StreamShortcutsStore: NSObject {
    private static let defaultsKey = "streamShortcuts.bindings"

    private static let defaultBindings:
        [StreamShortcutAction: StreamShortcutBinding] = [
            .releaseMouse: StreamShortcutBinding(
                keyCode: nil,
                modifiers: [.control, .option]
            ),
            .openControlCenter: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_C),
                modifiers: [.control, .option]
            ),
            .disconnectStream: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_W),
                modifiers: [.control, .option]
            ),
            .toggleConnectionDetails: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_S),
                modifiers: [.control, .option]
            ),
            .toggleMouseMode: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_M),
                modifiers: [.control, .option]
            ),
            .toggleFullscreenControlBall: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_G),
                modifiers: [.control, .option]
            ),
            .toggleBorderlessWindow: StreamShortcutBinding(
                keyCode: UInt16(kVK_ANSI_B),
                modifiers: [.control, .option, .command]
            ),
        ]

    private static let reservedBindings: [StreamShortcutBinding] = [
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_W),
            modifiers: [.command]
        ),
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_H),
            modifiers: [.command]
        ),
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_Grave),
            modifiers: [.command]
        ),
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_1),
            modifiers: [.command]
        ),
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_F),
            modifiers: [.control, .command]
        ),
        StreamShortcutBinding(
            keyCode: UInt16(kVK_ANSI_F),
            modifiers: [.function]
        ),
    ]

    @objc(didChangeNotification)
    static var didChangeNotification: NSNotification.Name {
        .streamShortcutsDidChange
    }

    @objc(bindingDisplayStringFor:)
    static func bindingDisplayString(for action: StreamShortcutAction) -> String
    {
        guard let binding = binding(for: action) else {
            return LanguageManager.shared.localize("Unassigned")
        }
        return displayString(for: binding)
    }

    @objc(menuKeyEquivalentFor:)
    static func menuKeyEquivalent(for action: StreamShortcutAction) -> String {
        guard let binding = binding(for: action) else { return "" }
        return keyLabel(for: binding)?.menuEquivalent ?? ""
    }

    @objc(menuModifierFlagsRawValueFor:)
    static func menuModifierFlagsRawValue(for action: StreamShortcutAction)
        -> UInt
    {
        binding(for: action)?.modifiersRawValue ?? 0
    }

    @objc(actionForKeyEvent:)
    static func actionForKeyEvent(_ event: NSEvent) -> NSNumber? {
        for action in StreamShortcutAction.allCases {
            guard let binding = binding(for: action), !binding.isModifierOnly
            else { continue }
            if binding.matches(keyEvent: event) {
                return NSNumber(value: action.rawValue)
            }
        }

        return nil
    }

    @objc(modifierOnlyActionForModifierFlagsRawValue:)
    static func modifierOnlyAction(for modifierFlagsRawValue: UInt) -> NSNumber?
    {
        let modifiers = StreamShortcutBinding.normalize(
            NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        )

        for action in StreamShortcutAction.allCases {
            guard let binding = binding(for: action), binding.isModifierOnly
            else { continue }
            if binding.matches(modifierFlags: modifiers) {
                return NSNumber(value: action.rawValue)
            }
        }

        return nil
    }

    @objc(restoreDefaults)
    static func restoreDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        postDidChangeNotification()
    }

    @objc(isShortcutConfiguredFor:)
    static func isShortcutConfigured(for action: StreamShortcutAction) -> Bool {
        binding(for: action) != nil
    }

    static func binding(for action: StreamShortcutAction)
        -> StreamShortcutBinding?
    {
        if let persisted = loadPersistedBindings()[action.storageKey] {
            return persisted.binding
        }

        return defaultBindings[action]
    }

    static func effectiveBindings() -> [StreamShortcutAction:
        StreamShortcutBinding?]
    {
        Dictionary(
            uniqueKeysWithValues: StreamShortcutAction.allCases.map { action in
                (action, binding(for: action))
            }
        )
    }

    static func setBinding(
        _ binding: StreamShortcutBinding?,
        for action: StreamShortcutAction
    ) throws {
        if let binding {
            guard binding.isValid else { return }

            if reservedBindings.contains(binding) {
                throw StreamShortcutValidationError.reserved
            }

            if let conflictingAction = conflictingAction(
                for: binding,
                excluding: action
            ) {
                throw StreamShortcutValidationError.duplicate(conflictingAction)
            }
        }

        var persisted = loadPersistedBindings()
        persisted[action.storageKey] = PersistedStreamShortcutBinding(
            binding: binding
        )
        savePersistedBindings(persisted)
        postDidChangeNotification()
    }

    static func displayString(for binding: StreamShortcutBinding) -> String {
        var result = modifierGlyphString(for: binding.modifiers)
        if let keyLabel = keyLabel(for: binding)?.display {
            result += keyLabel
        }
        return result
    }

    static func localizedErrorMessage(for error: Error) -> String {
        let languageManager = LanguageManager.shared

        switch error {
        case StreamShortcutValidationError.duplicate(let action):
            let format = languageManager.localize("Shortcut Conflict: %@")
            return String(
                format: format,
                languageManager.localize(action.titleKey)
            )
        case StreamShortcutValidationError.reserved:
            return languageManager.localize(
                "Shortcut is reserved by the app or system."
            )
        default:
            return languageManager.localize("Failed to save shortcut.")
        }
    }

    private static func postDidChangeNotification() {
        NotificationCenter.default.post(
            name: .streamShortcutsDidChange,
            object: nil
        )
    }

    private static func conflictingAction(
        for currentBinding: StreamShortcutBinding,
        excluding actionToExclude: StreamShortcutAction
    ) -> StreamShortcutAction? {
        for action in StreamShortcutAction.allCases
        where action != actionToExclude {
            if binding(for: action) == currentBinding {
                return action
            }
        }

        return nil
    }

    private static func loadPersistedBindings() -> [String:
        PersistedStreamShortcutBinding]
    {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return [:]
        }
        return
            (try? PropertyListDecoder().decode(
                [String: PersistedStreamShortcutBinding].self,
                from: data
            )) ?? [:]
    }

    private static func savePersistedBindings(
        _ bindings: [String: PersistedStreamShortcutBinding]
    ) {
        if let data = try? PropertyListEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func modifierGlyphString(
        for modifiers: NSEvent.ModifierFlags
    ) -> String {
        var result = ""

        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        if modifiers.contains(.function) {
            result += "fn"
        }

        return result
    }

    private static func keyLabel(for binding: StreamShortcutBinding)
        -> StreamShortcutKeyLabel?
    {
        guard let keyCode = binding.keyCode else { return nil }
        return keyLabel(for: keyCode)
    }

    private static func keyLabel(for keyCode: UInt16) -> StreamShortcutKeyLabel
    {
        if let special = specialKeyLabel(for: keyCode) {
            return special
        }

        if let translated = translatedKeyString(for: keyCode),
            !translated.isEmpty
        {
            let display = translated.uppercased()
            let menuEquivalent = translated.lowercased()
            return StreamShortcutKeyLabel(
                display: display,
                menuEquivalent: menuEquivalent
            )
        }

        return StreamShortcutKeyLabel(
            display: "Key \(keyCode)",
            menuEquivalent: nil
        )
    }

    private static func specialKeyLabel(for keyCode: UInt16)
        -> StreamShortcutKeyLabel?
    {
        switch Int(keyCode) {
        case kVK_Return:
            return StreamShortcutKeyLabel(display: "↩", menuEquivalent: "\r")
        case kVK_Tab:
            return StreamShortcutKeyLabel(display: "⇥", menuEquivalent: "\t")
        case kVK_Space:
            return StreamShortcutKeyLabel(display: "Space", menuEquivalent: " ")
        case kVK_Delete:
            return StreamShortcutKeyLabel(
                display: "⌫",
                menuEquivalent: "\u{08}"
            )
        case kVK_ForwardDelete:
            return StreamShortcutKeyLabel(
                display: "⌦",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSDeleteFunctionKey)!)
                )
            )
        case kVK_Escape:
            return StreamShortcutKeyLabel(
                display: "⎋",
                menuEquivalent: "\u{1B}"
            )
        case kVK_LeftArrow:
            return StreamShortcutKeyLabel(
                display: "←",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSLeftArrowFunctionKey)!)
                )
            )
        case kVK_RightArrow:
            return StreamShortcutKeyLabel(
                display: "→",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSRightArrowFunctionKey)!)
                )
            )
        case kVK_UpArrow:
            return StreamShortcutKeyLabel(
                display: "↑",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSUpArrowFunctionKey)!)
                )
            )
        case kVK_DownArrow:
            return StreamShortcutKeyLabel(
                display: "↓",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSDownArrowFunctionKey)!)
                )
            )
        case kVK_PageUp:
            return StreamShortcutKeyLabel(
                display: "⇞",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSPageUpFunctionKey)!)
                )
            )
        case kVK_PageDown:
            return StreamShortcutKeyLabel(
                display: "⇟",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSPageDownFunctionKey)!)
                )
            )
        case kVK_Home:
            return StreamShortcutKeyLabel(
                display: "↖",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSHomeFunctionKey)!)
                )
            )
        case kVK_End:
            return StreamShortcutKeyLabel(
                display: "↘",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSEndFunctionKey)!)
                )
            )
        case kVK_Help:
            return StreamShortcutKeyLabel(
                display: "Help",
                menuEquivalent: String(
                    Character(UnicodeScalar(NSHelpFunctionKey)!)
                )
            )
        case kVK_F1:
            return functionKeyLabel("F1", scalarValue: NSF1FunctionKey)
        case kVK_F2:
            return functionKeyLabel("F2", scalarValue: NSF2FunctionKey)
        case kVK_F3:
            return functionKeyLabel("F3", scalarValue: NSF3FunctionKey)
        case kVK_F4:
            return functionKeyLabel("F4", scalarValue: NSF4FunctionKey)
        case kVK_F5:
            return functionKeyLabel("F5", scalarValue: NSF5FunctionKey)
        case kVK_F6:
            return functionKeyLabel("F6", scalarValue: NSF6FunctionKey)
        case kVK_F7:
            return functionKeyLabel("F7", scalarValue: NSF7FunctionKey)
        case kVK_F8:
            return functionKeyLabel("F8", scalarValue: NSF8FunctionKey)
        case kVK_F9:
            return functionKeyLabel("F9", scalarValue: NSF9FunctionKey)
        case kVK_F10:
            return functionKeyLabel("F10", scalarValue: NSF10FunctionKey)
        case kVK_F11:
            return functionKeyLabel("F11", scalarValue: NSF11FunctionKey)
        case kVK_F12:
            return functionKeyLabel("F12", scalarValue: NSF12FunctionKey)
        case kVK_F13:
            return functionKeyLabel("F13", scalarValue: NSF13FunctionKey)
        case kVK_F14:
            return functionKeyLabel("F14", scalarValue: NSF14FunctionKey)
        case kVK_F15:
            return functionKeyLabel("F15", scalarValue: NSF15FunctionKey)
        case kVK_F16:
            return functionKeyLabel("F16", scalarValue: NSF16FunctionKey)
        case kVK_F17:
            return functionKeyLabel("F17", scalarValue: NSF17FunctionKey)
        case kVK_F18:
            return functionKeyLabel("F18", scalarValue: NSF18FunctionKey)
        case kVK_F19:
            return functionKeyLabel("F19", scalarValue: NSF19FunctionKey)
        case kVK_F20:
            return functionKeyLabel("F20", scalarValue: NSF20FunctionKey)
        default:
            return nil
        }
    }

    private static func functionKeyLabel(_ title: String, scalarValue: Int)
        -> StreamShortcutKeyLabel
    {
        StreamShortcutKeyLabel(
            display: title,
            menuEquivalent: String(Character(UnicodeScalar(scalarValue)!))
        )
    }

    private static func translatedKeyString(for keyCode: UInt16) -> String? {
        guard
            let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?
                .takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
            )
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let keyboardLayout = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyboardLayoutPointer = UnsafePointer<UCKeyboardLayout>(
            OpaquePointer(keyboardLayout)
        )
        let keyboardType = UInt32(LMGetKbdType())

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var actualLength = 0

        let status = UCKeyTranslate(
            keyboardLayoutPointer,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )

        guard status == noErr, actualLength > 0 else {
            return nil
        }

        let string = Array(characters.prefix(Int(actualLength))).stringValue
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return string.isEmpty ? nil : string
    }
}

@MainActor
final class StreamShortcutSettingsModel: ObservableObject {
    @Published private(set) var bindings:
        [StreamShortcutAction: StreamShortcutBinding?] = [:]
    @Published var errorMessage = ""
    @Published var recordingAction: StreamShortcutAction?
    @Published var recordingPreview = ""

    private var changeObserver: Any?
    private var keyDownMonitor: Any?
    private var flagsChangedMonitor: Any?
    private weak var recordingWindow: NSWindow?
    private var pendingModifierBinding: StreamShortcutBinding?
    private var lastObservedModifierFlags: NSEvent.ModifierFlags = []

    init() {
        reload()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .streamShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
        }
    }

    func reload() {
        bindings = StreamShortcutsStore.effectiveBindings()
    }

    func displayText(for action: StreamShortcutAction) -> String {
        if recordingAction == action {
            return recordingPreview.isEmpty
                ? LanguageManager.shared.localize("Type shortcut")
                : recordingPreview
        }

        guard let binding = bindings[action] ?? nil else {
            return LanguageManager.shared.localize("Unassigned")
        }

        return StreamShortcutsStore.displayString(for: binding)
    }

    func beginRecording(_ action: StreamShortcutAction) {
        if recordingAction == action {
            stopRecording()
            return
        }

        stopRecording()
        errorMessage = ""
        recordingAction = action
        recordingPreview = ""
        recordingWindow = NSApp.keyWindow
        pendingModifierBinding = nil
        lastObservedModifierFlags = []

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            self?.handleFlagsChanged(event) ?? event
        }
    }

    func clear(_ action: StreamShortcutAction) {
        stopRecording()
        errorMessage = ""

        do {
            try StreamShortcutsStore.setBinding(nil, for: action)
            reload()
        } catch {
            errorMessage = StreamShortcutsStore.localizedErrorMessage(
                for: error
            )
        }
    }

    func restoreDefaults() {
        stopRecording()
        errorMessage = ""
        StreamShortcutsStore.restoreDefaults()
        reload()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard shouldCapture(event: event), let action = recordingAction else {
            return event
        }

        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }

        let binding = StreamShortcutBinding(
            keyCode: event.keyCode,
            modifiers: StreamShortcutBinding.normalize(event.modifierFlags)
        )
        commit(binding, for: action)
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard shouldCapture(event: event), let action = recordingAction else {
            return event
        }

        let modifiers = StreamShortcutBinding.normalize(event.modifierFlags)
        let previousModifiers = lastObservedModifierFlags
        lastObservedModifierFlags = modifiers

        if modifiers.isEmpty {
            if let pendingModifierBinding {
                commit(pendingModifierBinding, for: action)
            } else {
                stopRecording()
            }
            return nil
        }

        if shouldUpdatePendingModifierBinding(
            currentModifiers: modifiers,
            previousModifiers: previousModifiers
        ) {
            pendingModifierBinding = StreamShortcutBinding(
                keyCode: nil,
                modifiers: modifiers
            )
        }
        recordingPreview =
            pendingModifierBinding.map(StreamShortcutsStore.displayString(for:))
            ?? ""
        return nil
    }

    private func commit(
        _ binding: StreamShortcutBinding,
        for action: StreamShortcutAction
    ) {
        do {
            try StreamShortcutsStore.setBinding(binding, for: action)
            reload()
            stopRecording()
        } catch {
            errorMessage = StreamShortcutsStore.localizedErrorMessage(
                for: error
            )
            stopRecording(clearPreview: true, preserveError: true)
        }
    }

    private func shouldCapture(event: NSEvent) -> Bool {
        guard let recordingWindow else { return true }
        return event.window == nil || event.window == recordingWindow
    }

    private func shouldUpdatePendingModifierBinding(
        currentModifiers: NSEvent.ModifierFlags,
        previousModifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard pendingModifierBinding != nil else { return true }
        return modifierCount(currentModifiers)
            >= modifierCount(previousModifiers)
    }

    private func modifierCount(_ modifiers: NSEvent.ModifierFlags) -> Int {
        var count = 0
        if modifiers.contains(.control) {
            count += 1
        }
        if modifiers.contains(.option) {
            count += 1
        }
        if modifiers.contains(.shift) {
            count += 1
        }
        if modifiers.contains(.command) {
            count += 1
        }
        if modifiers.contains(.function) {
            count += 1
        }
        return count
    }

    private func stopRecording(
        clearPreview: Bool = true,
        preserveError: Bool = false
    ) {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
            self.flagsChangedMonitor = nil
        }

        pendingModifierBinding = nil
        lastObservedModifierFlags = []
        recordingWindow = nil
        recordingAction = nil

        if clearPreview {
            recordingPreview = ""
        }
        if !preserveError {
            errorMessage = ""
        }
    }
}

struct StreamShortcutSettingsSection: View {
    let isGlobalProfileSelected: Bool

    @StateObject private var model = StreamShortcutSettingsModel()
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(languageManager.localize("Streaming Shortcuts"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(languageManager.localize("Restore Defaults")) {
                    model.restoreDefaults()
                }
                .controlSize(.small)
            }

            if !isGlobalProfileSelected {
                Text(
                    languageManager.localize(
                        "Streaming shortcuts apply globally to all hosts."
                    )
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            ForEach(StreamShortcutAction.allCases) { action in
                StreamShortcutRow(action: action, model: model)
            }

            if !model.errorMessage.isEmpty {
                Text(model.errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
            } else if model.recordingAction != nil {
                Text(
                    languageManager.localize(
                        "Press the shortcut, or press Esc to cancel."
                    )
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreamShortcutRow: View {
    let action: StreamShortcutAction
    @ObservedObject var model: StreamShortcutSettingsModel
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(languageManager.localize(action.titleKey))
            Spacer()
            Group {
                if model.recordingAction == action {
                    Button {
                        model.beginRecording(action)
                    } label: {
                        Text(model.displayText(for: action))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                } else {
                    Button {
                        model.beginRecording(action)
                    } label: {
                        Text(model.displayText(for: action))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
            }
            .controlSize(.small)

            Button(languageManager.localize("Clear")) {
                model.clear(action)
            }
            .controlSize(.small)
            .disabled(!StreamShortcutsStore.isShortcutConfigured(for: action))
        }
    }
}
