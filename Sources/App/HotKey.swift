import Carbon.HIToolbox
import Foundation

// Global hotkey via the Carbon API, which needs no extra permissions
final class HotKey {
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private static weak var current: HotKey?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        HotKey.current = self
    }

    func register(_ combo: KeyCombo) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // 'CLIP'
        RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
