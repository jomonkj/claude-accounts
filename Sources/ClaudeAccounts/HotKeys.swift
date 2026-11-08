import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts with the Carbon hot key API. It needs no Accessibility permission.
@MainActor
final class HotKeys {
    enum Key: UInt32, CaseIterable {
        case openPanel = 1, nextAccount = 2

        /// UserDefaults key of the on/off switch. Both are on by default.
        var setting: String { self == .openPanel ? "shortcutOpenPanel" : "shortcutNextAccount" }
        var keyCode: Int { self == .openPanel ? kVK_ANSI_C : kVK_ANSI_N }
        /// Text for Settings.
        var label: String { self == .openPanel ? "⌃⌥⌘C" : "⌃⌥⌘N" }

        var isOn: Bool { UserDefaults.standard.object(forKey: setting) as? Bool ?? true }
    }

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let onPress: (Key) -> Void

    init(onPress: @escaping (Key) -> Void) { self.onPress = onPress }

    /// Registers the keys that are on and removes the keys that are off.
    func apply() {
        installHandler()
        for key in Key.allCases {
            if key.isOn, refs[key] == nil {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x4341_6363), id: key.rawValue)  // "CAcc"
                let mods = UInt32(controlKey | optionKey | cmdKey)
                if RegisterEventHotKey(UInt32(key.keyCode), mods, id, GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                    refs[key] = ref
                }
            } else if !key.isOn, let ref = refs.removeValue(forKey: key) {
                UnregisterEventHotKey(ref)
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
            var id = EventHotKeyID()
            guard let event, let data,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  let key = HotKeys.Key(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.onPress(key) }
            return noErr
        }, 1, &spec, me, &handler)
    }
}
