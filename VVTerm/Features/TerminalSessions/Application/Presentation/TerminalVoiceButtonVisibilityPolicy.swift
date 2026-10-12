nonisolated enum TerminalVoiceButtonVisibilityPolicy {
    static func isVisible(
        settingEnabled: Bool,
        tabSelected: Bool,
        paneFocused: Bool,
        recording: Bool
    ) -> Bool {
        isAccessoryVisible(settingEnabled: settingEnabled, recording: recording)
            && tabSelected && paneFocused
    }

    static func isAccessoryVisible(settingEnabled: Bool, recording: Bool) -> Bool {
        // Availability stays stable while UIKit transfers the active accessory.
        settingEnabled && !recording
    }
}
