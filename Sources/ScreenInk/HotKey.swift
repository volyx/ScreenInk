import Carbon.HIToolbox
import ScreenInkCore

/// A system-wide hotkey via Carbon `RegisterEventHotKey`. Needs no permission (PLAN.md §2).
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var dispatcherInstalled = false
    private static let signature: OSType = 0x5349_4E4B  // 'SINK'

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Returns nil when another app already owns the combination.
    init?(_ spec: HotKeySpec, handler: @escaping () -> Void) {
        Self.installDispatcherIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, Self.carbonModifiers(spec.modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func carbonModifiers(_ modifiers: Set<HotKeySpec.Modifier>) -> UInt32 {
        var mask = 0
        if modifiers.contains(.ctrl) { mask |= controlKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        if modifiers.contains(.cmd) { mask |= cmdKey }
        return UInt32(mask)
    }

    private static func installDispatcherIfNeeded() {
        guard !dispatcherInstalled else { return }
        dispatcherInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == HotKey.signature else { return status }
                let id = hotKeyID.id
                // Carbon delivers hotkey events on the main thread's event loop.
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
    }
}
