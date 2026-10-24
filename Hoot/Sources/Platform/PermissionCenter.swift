//
//  PermissionCenter.swift
//  Hoot
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

/// Microphone, Accessibility, Screen Recording and Screen Content permissions.
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    /// ScreenCaptureKit's own consent (SCShareableContent succeeds).
    @Published private(set) var hasScreenContentPermission = false

    var grantedPermissionCount: Int {
        [hasMicrophonePermission, hasAccessibilityPermission, hasScreenRecordingPermission, hasScreenContentPermission]
            .filter { $0 }.count
    }
    var allPermissionsGranted: Bool { grantedPermissionCount == 4 }

    private var permissionPollingTimer: Timer?
    /// SCShareableContent is an async round trip to the window server; never stack them up.
    private var isScreenContentCheckInFlight = false

    /// Re-checks every permission about once a second while the app runs, because
    /// macOS never tells us when the learner flips a switch in System Settings.
    func startPolling() {
        refreshNow()
        guard permissionPollingTimer == nil else { return }
        permissionPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    func refreshNow() {
        let microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        setIfChanged(\.hasMicrophonePermission, to: microphoneAuthorizationStatus == .authorized)
        setIfChanged(\.hasAccessibilityPermission, to: AXIsProcessTrusted())

        let screenRecordingPreflightPassed = CGPreflightScreenCaptureAccess()
        setIfChanged(\.hasScreenRecordingPermission, to: screenRecordingPreflightPassed)

        // Only probe ScreenCaptureKit once screen recording is granted: probing
        // without it would pop the system consent dialog every second.
        if screenRecordingPreflightPassed {
            checkScreenContentPermission()
        } else {
            setIfChanged(\.hasScreenContentPermission, to: false)
        }
    }

    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor [weak self] in self?.refreshNow() }
            }
        case .authorized:
            refreshNow()
        default:
            // Once denied, macOS never shows the prompt again; only System Settings can fix it.
            openSystemSettingsPane(named: "Privacy_Microphone")
        }
    }

    func requestAccessibilityPermission() {
        let promptOptionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let isAlreadyTrusted = AXIsProcessTrustedWithOptions([promptOptionKey: true] as CFDictionary)
        if !isAlreadyTrusted {
            openSystemSettingsForAccessibility()
        }
        refreshNow()
    }

    func requestScreenRecordingPermission() {
        // Returns false right away when not yet granted; the grant only takes
        // effect after the learner toggles hoot on in System Settings.
        let wasGranted = CGRequestScreenCaptureAccess()
        if !wasGranted {
            openSystemSettingsForScreenRecording()
        }
        refreshNow()
    }

    func requestScreenContentPermission() {
        // Asking ScreenCaptureKit for shareable content is what shows its consent dialog.
        Task { @MainActor [weak self] in
            _ = try? await SCShareableContent.current
            self?.refreshNow()
        }
    }

    /// Opens the right System Settings pane for each permission.
    func openSystemSettingsForAccessibility() {
        openSystemSettingsPane(named: "Privacy_Accessibility")
    }

    func openSystemSettingsForScreenRecording() {
        openSystemSettingsPane(named: "Privacy_ScreenCapture")
    }

    private func openSystemSettingsPane(named privacyPaneAnchor: String) {
        guard let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPaneAnchor)") else { return }
        NSWorkspace.shared.open(systemSettingsURL)
    }

    private func checkScreenContentPermission() {
        guard !isScreenContentCheckInFlight else { return }
        isScreenContentCheckInFlight = true
        Task { @MainActor [weak self] in
            let screenContentIsAvailable: Bool
            do {
                _ = try await SCShareableContent.current
                screenContentIsAvailable = true
            } catch {
                screenContentIsAvailable = false
            }
            guard let self else { return }
            self.isScreenContentCheckInFlight = false
            self.setIfChanged(\.hasScreenContentPermission, to: screenContentIsAvailable)
        }
    }

    /// Publishing an unchanged value every second would re-render every observing view.
    private func setIfChanged(_ permissionKeyPath: ReferenceWritableKeyPath<PermissionCenter, Bool>, to newValue: Bool) {
        if self[keyPath: permissionKeyPath] != newValue {
            self[keyPath: permissionKeyPath] = newValue
        }
    }
}
