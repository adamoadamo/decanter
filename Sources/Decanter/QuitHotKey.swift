import Carbon

/// A system-wide ⌘Q hotkey, switched on only while one of Decanter's games is the frontmost
/// app. Wine games are separate apps, so this is how ⌘Q reaches Decanter while you play.
/// Carbon hotkeys need no Accessibility permission. When the hotkey is off, ⌘Q behaves
/// normally in every app.
final class QuitHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<QuitHotKey>.fromOpaque(context).takeUnretainedValue().onPress()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                let id = EventHotKeyID(signature: OSType(0x5942_4751), id: 1) // "YBGQ"
                RegisterEventHotKey(UInt32(kVK_ANSI_Q), UInt32(cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
            } else if let hotKey {
                UnregisterEventHotKey(hotKey)
                self.hotKey = nil
            }
        }
    }
}
