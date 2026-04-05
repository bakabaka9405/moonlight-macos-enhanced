//
//  MicrophoneManager.swift
//  Moonlight for macOS
//
//  Manages microphone device enumeration, permission status, and input level metering.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import Security
import SwiftUI

struct MicrophoneDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

class MicrophoneManager: ObservableObject {
    static let shared = MicrophoneManager()

    @Published var devices: [MicrophoneDevice] = []
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var inputLevel: Float = 0
    @Published var isTesting: Bool = false

    @AppStorage("selectedMicDeviceUID") var selectedDeviceUID: String = ""

    private var testEngine: AVAudioEngine?
    private var levelTimer: Timer?

    init() {
        refreshDevices()
        refreshPermissionStatus()
        installDeviceChangeListener()
    }

    deinit {
        removeDeviceChangeListener()
        stopTest()
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr
        else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs)
            == noErr
        else { return }

        var result: [MicrophoneDevice] = []
        for id in deviceIDs {
            // Check if device has input channels
            var inputScope = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputScope, 0, nil, &bufSize) == noErr,
                  bufSize > 0 else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            guard AudioObjectGetPropertyData(id, &inputScope, 0, nil, &bufSize, bufferList) == noErr
            else { continue }

            let inputChannels = UnsafeMutableAudioBufferListPointer(bufferList)
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get UID
            var uidProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidProp, 0, nil, &uidSize, &uidRef) == noErr,
                let uid = uidRef?.takeUnretainedValue()
            else { continue }

            // Get Name
            var nameProp = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameProp, 0, nil, &nameSize, &nameRef) == noErr,
                let name = nameRef?.takeUnretainedValue()
            else { continue }

            result.append(MicrophoneDevice(
                id: id,
                uid: uid as String,
                name: name as String
            ))
        }

        DispatchQueue.main.async {
            self.devices = result
            // If selection invalid, clear it (will use system default)
            if !self.selectedDeviceUID.isEmpty,
               !result.contains(where: { $0.uid == self.selectedDeviceUID })
            {
                self.selectedDeviceUID = ""
            }
        }
    }

    // MARK: - Device Change Listener

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func installDeviceChangeListener() {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main, block)
    }

    private func removeDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main, block)
        listenerBlock = nil
    }

    // MARK: - Permissions

    func refreshPermissionStatus() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissionStatus()
            }
        }
    }

    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Test (Level Metering)

    func startTest() {
        guard !isTesting else { return }

        let engine = AVAudioEngine()

        // Set selected device if not default
        if !selectedDeviceUID.isEmpty,
           let device = devices.first(where: { $0.uid == selectedDeviceUID })
        {
            setAudioUnitDevice(engine.inputNode, deviceID: device.id)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            var maxVal: Float = 0
            for i in 0..<count {
                let abs = Swift.abs(data[0][i])
                if abs > maxVal { maxVal = abs }
            }
            DispatchQueue.main.async {
                // Smooth the level a bit
                self?.inputLevel = max(maxVal, (self?.inputLevel ?? 0) * 0.7)
            }
        }

        do {
            try engine.start()
            testEngine = engine
            isTesting = true

            // Auto-stop after 15 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.stopTest()
            }
        } catch {
            NSLog("Mic test failed to start: %@", error.localizedDescription)
        }
    }

    func stopTest() {
        guard isTesting else { return }
        testEngine?.inputNode.removeTap(onBus: 0)
        testEngine?.stop()
        testEngine = nil
        isTesting = false
        inputLevel = 0
    }

    // MARK: - Helpers

    /// Get the AudioDeviceID for the selected device, or 0 for system default.
    @objc var selectedAudioDeviceID: AudioDeviceID {
        guard !selectedDeviceUID.isEmpty,
              let device = devices.first(where: { $0.uid == selectedDeviceUID })
        else { return 0 }
        return device.id
    }

    private func setAudioUnitDevice(_ inputNode: AVAudioInputNode, deviceID: AudioDeviceID) {
        var deviceID = deviceID
        let audioUnit = inputNode.audioUnit!
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}

@objc enum AwdlHelperAuthorizationState: Int {
    case notDetermined = 0
    case ready = 1
    case failed = 2
    case unavailable = 3
}

private struct AwdlInterfaceState {
    let present: Bool
    let up: Bool
    let stderr: String
}

@objcMembers
final class AwdlHelperManager: NSObject, ObservableObject {
    @objc(sharedManager) static let sharedManager = AwdlHelperManager()

    @Published var authorizationState: AwdlHelperAuthorizationState = .notDetermined {
        didSet {
            UserDefaults.standard.set(authorizationState.rawValue, forKey: Self.authorizationStateKey)
        }
    }
    @Published var lastErrorMessage: String = "" {
        didSet {
            UserDefaults.standard.set(lastErrorMessage, forKey: Self.lastErrorMessageKey)
        }
    }
    @Published var isRequestingAuthorization: Bool = false

    private static let authorizationStateKey = "networkCompatibility.awdlHelperAuthorizationState"
    private static let lastErrorMessageKey = "networkCompatibility.awdlHelperLastErrorMessage"
    private static let pendingRestoreKey = "networkCompatibility.awdlHelperPendingRestore"

    private let sessionQueue = DispatchQueue(label: "moonlight.awdl.helper")
    private let isSandboxedBuild = AwdlHelperManager.detectSandboxedBuild()
    private var appWillTerminateObserver: NSObjectProtocol?
    private var sessionGeneration: UInt = 0
    private var sessionEnabled = false
    private var interfacePresent = false
    private var originalInterfaceUp = false
    private var changedInterfaceState = false

    override init() {
        super.init()

        if UserDefaults.standard.object(forKey: Self.authorizationStateKey) != nil {
            authorizationState = AwdlHelperAuthorizationState(
                rawValue: UserDefaults.standard.integer(forKey: Self.authorizationStateKey)
            ) ?? .notDetermined
        }
        if let lastError = UserDefaults.standard.string(forKey: Self.lastErrorMessageKey) {
            lastErrorMessage = lastError
        }
        appWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationWillTerminate()
        }
        refreshAuthorizationStatus()
    }

    deinit {
        if let appWillTerminateObserver {
            NotificationCenter.default.removeObserver(appWillTerminateObserver)
        }
        MLAwdlAuthorizationHelper.invalidateSession()
    }

    private func logInfo(_ message: String) {
        LogMessage(LOG_I, message)
    }

    private func logWarning(_ message: String) {
        LogMessage(LOG_W, message)
    }

    private var pendingRestoreRequired: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pendingRestoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingRestoreKey) }
    }

    private static func detectSandboxedBuild() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              )
        else {
            return false
        }

        return (value as? Bool) ?? false
    }

    func refreshAuthorizationStatus() {
        sessionQueue.async {
            let state = self.queryAwdlInterfaceState()
            if state.present && state.up && self.pendingRestoreRequired {
                self.pendingRestoreRequired = false
            }
            DispatchQueue.main.async {
                if !state.present {
                    self.logInfo("[diag] AWDL helper status: awdl0 unavailable")
                    self.authorizationState = .unavailable
                    return
                }

                if self.authorizationState == .unavailable {
                    self.logInfo("[diag] AWDL helper status: awdl0 available")
                    self.authorizationState = .notDetermined
                }
            }
        }
    }

    func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isRequestingAuthorization = true
            NSApp.activate(ignoringOtherApps: true)
        }

        sessionQueue.async {
            self.logInfo("[diag] AWDL helper authorization environment: sandbox=\(self.isSandboxedBuild ? 1 : 0)")
            self.logInfo("[diag] AWDL helper authorization request started")
            let result = self.performAuthorizationProbe()
            DispatchQueue.main.async {
                self.isRequestingAuthorization = false
                self.updateAuthorizationState(result.state, message: result.message)
                switch result.state {
                case .ready:
                    self.logInfo("[diag] AWDL helper authorization request succeeded")
                case .failed:
                    self.logWarning("[diag] AWDL helper authorization request failed: \(result.message)")
                case .unavailable:
                    self.logInfo("[diag] AWDL helper authorization request skipped: awdl0 unavailable")
                case .notDetermined:
                    self.logInfo("[diag] AWDL helper authorization request ended without state change")
                }
                completion?(result.state == .ready)
            }
        }
    }

    @objc(beginStreamSessionIfEnabled:generation:)
    func beginStreamSessionIfEnabled(_ enabled: Bool, generation: UInt) {
        sessionQueue.async {
            self.restoreIfNeededLocked(reason: "superseded-by-new-stream")
            self.resetSessionStateLocked()

            if !enabled {
                self.logInfo("[diag] AWDL helper disabled for stream generation=\(generation)")
                return
            }

            self.sessionEnabled = true
            self.sessionGeneration = generation

            let state = self.queryAwdlInterfaceState()
            self.interfacePresent = state.present
            self.originalInterfaceUp = state.up

            if !self.interfacePresent {
                self.logInfo("[diag] AWDL helper found no awdl0 interface for generation=\(generation)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.unavailable, message: "")
                }
                return
            }

            if self.pendingRestoreRequired {
                if state.up {
                    self.pendingRestoreRequired = false
                } else {
                    self.originalInterfaceUp = true
                    self.changedInterfaceState = true
                    self.logWarning("[diag] AWDL helper found pending restore from a previous unfinished stream; keeping awdl0 down for generation=\(generation)")
                    DispatchQueue.main.async {
                        self.updateAuthorizationState(.ready, message: "")
                    }
                    return
                }
            }

            if !self.originalInterfaceUp {
                self.logInfo("[diag] AWDL helper found awdl0 already down for generation=\(generation)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.ready, message: "")
                }
                return
            }

            if let errorMessage = self.runPrivilegedIfconfigArgument("down") {
                self.logWarning("[diag] AWDL helper activation failed for generation=\(generation) error=\(errorMessage)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.failed, message: errorMessage)
                }
                return
            }

            self.changedInterfaceState = true
            self.pendingRestoreRequired = true
            let changedState = self.queryAwdlInterfaceState()
            self.logInfo("[diag] AWDL helper activated for generation=\(generation)")
            self.logInfo("[diag] AWDL helper post-activation state: present=\(changedState.present ? 1 : 0) up=\(changedState.up ? 1 : 0)")
            DispatchQueue.main.async {
                self.updateAuthorizationState(.ready, message: "")
            }
        }
    }

    @objc(endStreamSessionWithReason:)
    func endStreamSession(withReason reason: String?) {
        sessionQueue.async {
            self.restoreIfNeededLocked(reason: reason ?? "(unknown)")
            self.resetSessionStateLocked()
        }
    }

    private func performAuthorizationProbe() -> (state: AwdlHelperAuthorizationState, message: String) {
        let state = queryAwdlInterfaceState()
        guard state.present else {
            return (.unavailable, "")
        }

        let originalUp = state.up
        if let error = runPrivilegedIfconfigArgument("down") {
            return (.failed, error)
        }

        if originalUp, let restoreError = runPrivilegedIfconfigArgument("up") {
            return (.failed, restoreError)
        }

        let finalState = queryAwdlInterfaceState()
        if originalUp && !finalState.up {
            return (.failed, "Failed to restore AWDL interface state.")
        }

        return (.ready, "")
    }

    private func updateAuthorizationState(_ state: AwdlHelperAuthorizationState, message: String) {
        authorizationState = state
        lastErrorMessage = message
    }

    private func normalizedAuthorizationError(_ message: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return isSandboxedBuild
                ? "没有收到管理员授权结果。当前这个构建的安全限制可能拦住了系统授权窗。"
                : "没有收到管理员授权结果，请重试。"
        }

        if trimmedMessage.contains("(-128)") {
            return "你已取消管理员授权。"
        }

        if trimmedMessage.contains("(-60005)") {
            return isSandboxedBuild
                ? "系统没有正常弹出管理员授权窗口。当前这个构建的安全限制可能拦住了这类请求。"
                : "管理员授权没有完成，请确认当前账户有管理员权限后重试。"
        }

        if trimmedMessage.contains("(-10004)")
            || trimmedMessage.localizedCaseInsensitiveContains("not authorized")
            || trimmedMessage.localizedCaseInsensitiveContains("not permitted")
        {
            return "系统拦截了管理员授权请求。"
        }

        return trimmedMessage
    }

    private func awdlAuthorizationPrompt() -> String {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        let languageCode = preferredLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
        let key = "AWDL Helper Authorization Prompt"

        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = NSLocalizedString(
                key,
                tableName: nil,
                bundle: bundle,
                value: "___MISSING___",
                comment: ""
            )
            if localized != "___MISSING___" {
                return localized
            }
        }

        return "Moonlight needs administrator permission to manage the AWDL interface while streaming."
    }

    private func waitForInterfaceState(up expectedUp: Bool, attempts: Int = 20) -> Bool {
        for attempt in 0..<attempts {
            let state = queryAwdlInterfaceState()
            if !state.present {
                return false
            }
            if state.up == expectedUp {
                return true
            }
            if attempt + 1 < attempts {
                usleep(50_000)
            }
        }
        return false
    }

    private func runPrivilegedIfconfigViaAuthorizationHelper(_ argument: String) -> String? {
        let prompt = awdlAuthorizationPrompt()
        var errorMessage: NSString?
        let succeeded = MLAwdlAuthorizationHelper.runIfconfigArgument(
            argument,
            prompt: prompt,
            errorMessage: &errorMessage
        )
        guard succeeded else {
            return normalizedAuthorizationError((errorMessage as String?) ?? "Authorization failed.")
        }

        let expectedUp = (argument == "up")
        guard waitForInterfaceState(up: expectedUp) else {
            return expectedUp
                ? "Failed to restore AWDL interface state."
                : "Failed to disable AWDL interface."
        }

        return nil
    }

    private func runPrivilegedIfconfigViaAppleScript(_ argument: String) -> String? {
        let command = "/sbin/ifconfig awdl0 \(argument)"
        let appleScript = "do shell script \"\(Self.escapeForAppleScript(command))\" with administrator privileges"

        let executeAppleScript: () -> String? = {
            NSApp.activate(ignoringOtherApps: true)
            var error: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&error)
            guard let error else { return nil }

            if let message = error[NSAppleScript.errorMessage] as? String, !message.isEmpty {
                return message
            }
            return error.description
        }

        let mainThreadError: String?
        if Thread.isMainThread {
            mainThreadError = executeAppleScript()
        } else {
            var result: String?
            DispatchQueue.main.sync {
                result = executeAppleScript()
            }
            mainThreadError = result
        }

        if let mainThreadError {
            logWarning("[diag] AWDL helper NSAppleScript request failed: \(mainThreadError)")
        } else {
            logInfo("[diag] AWDL helper NSAppleScript request succeeded")
            return nil
        }

        let osascriptResult = runTask(launchPath: "/usr/bin/osascript", arguments: ["-e", appleScript])
        if osascriptResult.terminationStatus == 0 {
            logInfo("[diag] AWDL helper osascript fallback succeeded")
            return nil
        }

        let taskError = !osascriptResult.stderr.isEmpty ? osascriptResult.stderr : osascriptResult.stdout
        if !taskError.isEmpty {
            logWarning("[diag] AWDL helper osascript fallback failed: \(taskError)")
        }

        return normalizedAuthorizationError(!taskError.isEmpty ? taskError : (mainThreadError ?? ""))
    }

    private func runTask(launchPath: String, arguments: [String]) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        return (task.terminationStatus, stdoutText, stderrText)
    }

    private func queryAwdlInterfaceState() -> AwdlInterfaceState {
        let result = runTask(launchPath: "/sbin/ifconfig", arguments: ["awdl0"])
        guard result.terminationStatus == 0 else {
            return AwdlInterfaceState(present: false, up: false, stderr: result.stderr)
        }

        let stdoutText = result.stdout
        let isUp: Bool
        if let openRange = stdoutText.range(of: "<"),
           let closeRange = stdoutText.range(of: ">"),
           openRange.lowerBound < closeRange.lowerBound {
            let flagsString = String(stdoutText[openRange.upperBound..<closeRange.lowerBound])
            let flags = flagsString.split(separator: ",").map(String.init)
            isUp = flags.contains("UP")
        } else {
            isUp = stdoutText.contains("UP")
        }

        return AwdlInterfaceState(present: true, up: isUp, stderr: result.stderr)
    }

    private func runPrivilegedIfconfigArgument(_ argument: String) -> String? {
        let command = "/sbin/ifconfig awdl0 \(argument)"
        logInfo("[diag] AWDL helper requesting privileged command: \(command)")

        if !isSandboxedBuild {
            let hasBundledHelper = MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable()
            if let helperError = runPrivilegedIfconfigViaAuthorizationHelper(argument) {
                logWarning("[diag] AWDL privileged helper request failed: \(helperError)")
                if hasBundledHelper {
                    logInfo("[diag] AWDL helper falling back to administrator command prompt")
                    if let fallbackError = runPrivilegedIfconfigViaAppleScript(argument) {
                        return fallbackError
                    }
                    return nil
                }
                return helperError
            }
            logInfo("[diag] AWDL privileged helper request succeeded")
            return nil
        }

        return runPrivilegedIfconfigViaAppleScript(argument)
    }

    private static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func resetSessionStateLocked() {
        sessionEnabled = false
        interfacePresent = false
        originalInterfaceUp = false
        changedInterfaceState = false
        sessionGeneration = 0
    }

    private func restoreIfNeededLocked(reason: String) {
        guard sessionEnabled, interfacePresent, originalInterfaceUp, changedInterfaceState else {
            return
        }

        if let errorMessage = runPrivilegedIfconfigArgument("up") {
            logWarning("[diag] AWDL helper failed to restore pre-stream state: reason=\(reason) error=\(errorMessage)")
            DispatchQueue.main.async {
                self.updateAuthorizationState(.failed, message: errorMessage)
            }
            return
        }

        let restoredState = queryAwdlInterfaceState()
        pendingRestoreRequired = false
        logInfo("[diag] AWDL helper restored pre-stream state: reason=\(reason)")
        logInfo("[diag] AWDL helper restored state: present=\(restoredState.present ? 1 : 0) up=\(restoredState.up ? 1 : 0)")
        DispatchQueue.main.async {
            self.updateAuthorizationState(.ready, message: "")
        }
    }

    private func handleApplicationWillTerminate() {
        sessionQueue.sync {
            self.restoreIfNeededLocked(reason: "app-will-terminate")
            self.resetSessionStateLocked()
        }
    }
}
