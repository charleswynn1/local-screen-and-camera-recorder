import Carbon.HIToolbox
import Foundation

final class GlobalHotKeyManager: @unchecked Sendable {
    enum Action: UInt32 {
        case record = 1
        case pause = 2
    }

    private let handler: @MainActor @Sendable (Action) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyReferences = [EventHotKeyRef?]()
    private let signature: OSType = 0x4C_52_45_43 // LREC

    init(handler: @escaping @MainActor @Sendable (Action) -> Void) {
        self.handler = handler
        installEventHandler()
        register(keyCode: UInt32(kVK_ANSI_R), action: .record)
        register(keyCode: UInt32(kVK_ANSI_P), action: .pause)
    }

    deinit {
        for reference in hotKeyReferences {
            if let reference {
                UnregisterEventHotKey(reference)
            }
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, let action = Action(rawValue: identifier.id) else {
                    return status
                }
                Task { @MainActor in
                    manager.handler(action)
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }

    private func register(keyCode: UInt32, action: Action) {
        let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
        var reference: EventHotKeyRef?
        let modifiers = UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyReferences.append(reference)
        }
    }
}
