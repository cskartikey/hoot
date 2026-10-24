//
//  PushToTalkKeyMonitor.swift
//  Hoot
//
//  Watches the whole system for the ctrl+option chord so the learner can hold
//  it from any app to ask hoot a question out loud.
//
//  Why a CGEvent tap and not NSEvent.addGlobalMonitorForEvents: the global
//  NSEvent monitor silently stops delivering events in some apps (secure input
//  fields, some full-screen apps), and a session-level tap is the most reliable
//  way to see bare modifier changes. The tap is listen-only, so hoot never
//  swallows or changes anyone's keystrokes.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Publishes press / release of the ctrl+option chord from anywhere on the
/// system (listen-only CGEvent tap; needs Accessibility or Input Monitoring
/// permission). Only transitions are published: holding the chord produces
/// exactly one `.pressed`, letting go produces exactly one `.released`.
@MainActor
final class PushToTalkKeyMonitor {
    enum KeyTransition {
        case pressed
        case released
    }

    let keyTransitions = PassthroughSubject<KeyTransition, Never>()

    /// While permission is missing we keep trying on this interval, so the
    /// shortcut starts working the moment the learner flips the switch in
    /// System Settings — no relaunch needed.
    private static let secondsBetweenEventTapInstallRetries: TimeInterval = 2.0

    private var installedEventTapMachPort: CFMachPort?
    private var installedEventTapRunLoopSource: CFRunLoopSource?
    private var eventTapInstallRetryTimer: Timer?
    private var isPushToTalkChordCurrentlyHeld = false
    private var hasLoggedMissingPermissionOnce = false

    func startMonitoring() {
        guard installedEventTapMachPort == nil else { return }
        if installEventTapIfPermitted() {
            stopRetryingEventTapInstall()
        } else {
            startRetryingEventTapInstall()
        }
    }

    func stopMonitoring() {
        stopRetryingEventTapInstall()
        removeInstalledEventTap()
        // If the tap goes away mid-hold we would never see the release, which
        // would leave the rest of the app stuck "listening". Emit it ourselves.
        publishChordStateIfItChanged(isChordHeldNow: false)
    }

    // MARK: - Installing the tap

    /// Returns true when the tap is installed and enabled.
    private func installEventTapIfPermitted() -> Bool {
        // Creating a tap without permission either fails or yields a tap that
        // never fires; checking first avoids the second, silent case.
        let hasPermissionToListenToKeyboard = AXIsProcessTrusted() || CGPreflightListenEventAccess()
        guard hasPermissionToListenToKeyboard else {
            if !hasLoggedMissingPermissionOnce {
                hasLoggedMissingPermissionOnce = true
                print("[PushToTalkKeyMonitor] No Accessibility / Input Monitoring permission yet; will keep retrying.")
            }
            return false
        }

        let flagsChangedEventMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let unretainedSelfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTapMachPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: flagsChangedEventMask,
            callback: pushToTalkEventTapCallback,
            userInfo: unretainedSelfPointer
        ) else {
            print("[PushToTalkKeyMonitor] CGEvent.tapCreate failed even though permission looked granted; will retry.")
            return false
        }

        let eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTapMachPort, 0)
        // The main run loop on purpose: the callback then runs on the main
        // thread, which lets it hop straight into main-actor state.
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTapMachPort, enable: true)

        installedEventTapMachPort = eventTapMachPort
        installedEventTapRunLoopSource = eventTapRunLoopSource
        print("[PushToTalkKeyMonitor] Listening for ctrl+option system-wide.")

        // The chord might already be held while the tap comes up.
        synchronizeWithCurrentModifierState()
        return true
    }

    private func removeInstalledEventTap() {
        if let eventTapMachPort = installedEventTapMachPort {
            CGEvent.tapEnable(tap: eventTapMachPort, enable: false)
            CFMachPortInvalidate(eventTapMachPort)
        }
        if let eventTapRunLoopSource = installedEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        installedEventTapMachPort = nil
        installedEventTapRunLoopSource = nil
    }

    private func startRetryingEventTapInstall() {
        guard eventTapInstallRetryTimer == nil else { return }
        eventTapInstallRetryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.secondsBetweenEventTapInstallRetries,
            repeats: true
        ) { [weak self] _ in
            // Scheduled on the main run loop, so we are on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.installEventTapIfPermitted() {
                    self.stopRetryingEventTapInstall()
                }
            }
        }
    }

    private func stopRetryingEventTapInstall() {
        eventTapInstallRetryTimer?.invalidate()
        eventTapInstallRetryTimer = nil
    }

    // MARK: - Handling events

    fileprivate func handleEventFromTap(eventType: CGEventType, eventFlags: CGEventFlags) {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off if a callback is ever slow. Turn it back on,
            // and resync because we may have missed the release meanwhile.
            if let eventTapMachPort = installedEventTapMachPort {
                CGEvent.tapEnable(tap: eventTapMachPort, enable: true)
            }
            synchronizeWithCurrentModifierState()
        case .flagsChanged:
            publishChordStateIfItChanged(isChordHeldNow: Self.isPushToTalkChordHeld(in: eventFlags))
        default:
            break
        }
    }

    private func synchronizeWithCurrentModifierState() {
        let currentModifierFlags = CGEventSource.flagsState(.combinedSessionState)
        publishChordStateIfItChanged(isChordHeldNow: Self.isPushToTalkChordHeld(in: currentModifierFlags))
    }

    private func publishChordStateIfItChanged(isChordHeldNow: Bool) {
        guard isChordHeldNow != isPushToTalkChordCurrentlyHeld else { return }
        isPushToTalkChordCurrentlyHeld = isChordHeldNow
        keyTransitions.send(isChordHeldNow ? .pressed : .released)
    }

    /// Control and option both down, and no other "real" modifier. Command,
    /// shift and fn are excluded so ctrl+opt+cmd shortcuts in other apps don't
    /// trigger hoot. Caps lock is ignored on purpose: it is a toggle, and
    /// having it on shouldn't break push-to-talk.
    private static func isPushToTalkChordHeld(in modifierFlags: CGEventFlags) -> Bool {
        let isControlHeld = modifierFlags.contains(.maskControl)
        let isOptionHeld = modifierFlags.contains(.maskAlternate)
        let isAnyDisqualifyingModifierHeld = modifierFlags.contains(.maskCommand)
            || modifierFlags.contains(.maskShift)
            || modifierFlags.contains(.maskSecondaryFn)
        return isControlHeld && isOptionHeld && !isAnyDisqualifyingModifierHeld
    }
}

/// C callback for the event tap. It must be a plain function (no captures), so
/// the monitor instance comes in through `userInfo`. It runs on the main
/// thread because the tap's run loop source is on the main run loop.
nonisolated private func pushToTalkEventTapCallback(
    eventTapProxy: CGEventTapProxy,
    eventType: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let pushToTalkKeyMonitor = Unmanaged<PushToTalkKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let eventFlags = event.flags
        MainActor.assumeIsolated {
            pushToTalkKeyMonitor.handleEventFromTap(eventType: eventType, eventFlags: eventFlags)
        }
    }
    // Listen-only: always pass the event through untouched.
    return Unmanaged.passUnretained(event)
}
