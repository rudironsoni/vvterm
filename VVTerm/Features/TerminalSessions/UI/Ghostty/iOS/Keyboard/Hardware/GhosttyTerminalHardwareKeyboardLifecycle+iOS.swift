//
//  GhosttyTerminalHardwareKeyboardLifecycle+iOS.swift
//  VVTerm
//
//  iOS terminal hardware-keyboard observation and attachment lifecycle.
//

#if os(iOS)
import GameController
import UIKit

extension GhosttyTerminalView {
    enum HardwareKeyboardAttachment {
        case notDetected
        case disconnected
        case connected
        case detectedFromKeyPress

        var isAttached: Bool { self == .connected || self == .detectedFromKeyPress }

        func resolveSystemAttachment(_ attached: Bool) -> Bool {
            switch self {
            case .connected: true
            case .disconnected: false
            case .notDetected, .detectedFromKeyPress: attached
            }
        }
    }

    func setupHardwareKeyboardObservation() {
        guard hardwareKeyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateHardwareKeyboardState(attached: true, reloadInputViewsIfNeeded: true)
                }
            }
        )
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateHardwareKeyboardState(attached: false, reloadInputViewsIfNeeded: true)
                }
            }
        )
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    func removeHardwareKeyboardObservers() {
        for observer in hardwareKeyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        hardwareKeyboardObservers.removeAll()
    }

    func refreshHardwareKeyboardAttachmentFromSystem() {
        let hasHardwareKeyboard = detectedHardwareKeyboardAttached
        let previousInputConfiguration = terminalInputConfiguration
        if setHardwareKeyboardAttached(hasHardwareKeyboard) {
            reloadTerminalInputViews(
                ifChangedFrom: previousInputConfiguration
            )
        }
    }

    func updateHardwareKeyboardState(attached: Bool? = nil, reloadInputViewsIfNeeded: Bool) {
        var hasHardwareKeyboard = attached ?? detectedHardwareKeyboardAttached
        #if DEBUG
        if let keyboardUITestHardwareKeyboardOverride {
            hasHardwareKeyboard = keyboardUITestHardwareKeyboardOverride
        }
        #endif
        let previousInputConfiguration = terminalInputConfiguration
        // UIKit can report the same attachment more than once while presenting
        // input UI. Reloading an unchanged input view can move an open menu.
        guard setHardwareKeyboardAttached(hasHardwareKeyboard) else { return }
        logKeyboardLifecycle(
            "hardware.changed",
            detail: "attached=\(hasHardwareKeyboard) vendor=\(GCKeyboard.coalesced?.vendorName ?? "nil")"
        )
        reloadTerminalInputViews(ifChangedFrom: previousInputConfiguration)
        if hasHardwareKeyboard {
            focusForHardwareKeyboardIfNeeded()
        } else if isTerminalTextInputActive, isTextInputSessionEligible, !isFindNavigatorActive {
            _ = requestKeyboardFocus(for: .initialActivation)
        }
        if reloadInputViewsIfNeeded,
           previousInputConfiguration == terminalInputConfiguration,
           isTerminalTextInputActive,
           isTextInputSessionEligible {
            reloadTerminalInputViewsIfActive()
        }
    }

    @discardableResult
    func setHardwareKeyboardAttached(_ attached: Bool) -> Bool {
        let attachment: HardwareKeyboardAttachment = attached ? .connected : .disconnected
        guard attachment != hardwareKeyboardAttachment else { return false }
        if !attached {
            cancelTrackedHardwareInput()
        }
        hardwareKeyboardAttachment = attachment
        onHardwareKeyboardAttachmentChange?()
        return true
    }

    func markHardwareKeyboardDetectedFromKeyPress() {
        #if DEBUG
        if keyboardUITestHardwareKeyboardOverride == false { return }
        #endif
        guard !hasHardwareKeyboardAttached else { return }
        let previousInputConfiguration = terminalInputConfiguration
        hardwareKeyboardAttachment = .detectedFromKeyPress
        reloadTerminalInputViews(
            ifChangedFrom: previousInputConfiguration
        )
        onHardwareKeyboardAttachmentChange?()
        focusForHardwareKeyboardIfNeeded()
    }

    private var detectedHardwareKeyboardAttached: Bool {
        #if DEBUG
        if let keyboardUITestHardwareKeyboardOverride {
            return keyboardUITestHardwareKeyboardOverride
        }
        #endif
        // Connection notifications are authoritative even when the system
        // property has not caught up. A key-only fallback can still expire
        // on a negative system probe (for example, after remote input ends).
        return hardwareKeyboardAttachment.resolveSystemAttachment(GCKeyboard.coalesced != nil)
    }
}

#endif
