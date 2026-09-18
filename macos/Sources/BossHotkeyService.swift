import AppKit
import Carbon
import Foundation

enum StudioHotkeyID: UInt32 {
    case boss = 1
    case readerPrev = 2
    case readerNext = 3
    case readerPause = 4
}

final class BossHotkeyService {
    var onAction: ((StudioHotkeyID) -> Void)?

    private var hotKeyRefs: [StudioHotkeyID: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature = OSType(0x44575053)

    func apply(_ bindings: [(StudioHotkeyID, String, Bool)]) throws {
        unregister()
        installHandlerIfNeeded()
        var firstError: Error?
        for (action, gesture, enabled) in bindings {
            guard enabled else { continue }
            do {
                try register(action, gesture: gesture)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func unregister() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func register(_ action: StudioHotkeyID, gesture: String) throws {
        let parsed = try Self.parse(gesture)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw NSError(domain: "StudioHotkey", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法注册快捷键 \(gesture)。这个组合可能已被占用。"
            ])
        }
        hotKeyRefs[action] = ref
    }

    static func parse(_ gesture: String) throws -> (keyCode: UInt32, modifiers: UInt32) {
        let parts = gesture
            .split(whereSeparator: { $0 == "+" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw NSError(domain: "StudioHotkey", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "快捷键格式无效。请使用类似 Control+Option+Right 的组合。"
            ])
        }

        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for part in parts {
            let token = part.lowercased()
            if token == "ctrl" || token == "control" {
                modifiers |= UInt32(controlKey)
            } else if token == "alt" || token == "option" {
                modifiers |= UInt32(optionKey)
            } else if token == "shift" {
                modifiers |= UInt32(shiftKey)
            } else if token == "cmd" || token == "command" || token == "win" {
                modifiers |= UInt32(cmdKey)
            } else if let code = keyCodes[part.uppercased()] {
                keyCode = code
            } else {
                throw NSError(domain: "StudioHotkey", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "快捷键格式无效。请使用类似 Control+Option+Right 的组合。"
                ])
            }
        }
        guard let keyCode else {
            throw NSError(domain: "StudioHotkey", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "快捷键格式无效。请使用类似 Control+Option+Right 的组合。"
            ])
        }
        return (keyCode, modifiers)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr, let action = StudioHotkeyID(rawValue: hotKeyID.id) else { return noErr }
                let service = Unmanaged<BossHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onAction?(action)
                }
                return noErr
            },
            1,
            &spec,
            context,
            &ref
        )
        if status == noErr {
            handlerRef = ref
        }
    }

    private static let keyCodes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C),
            "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F),
            "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I),
            "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
            "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O),
            "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R),
            "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U),
            "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
            "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
            "SPACE": UInt32(kVK_Space),
            "ESC": UInt32(kVK_Escape),
            "ESCAPE": UInt32(kVK_Escape),
            "RETURN": UInt32(kVK_Return),
            "LEFT": UInt32(kVK_LeftArrow),
            "LEFTARROW": UInt32(kVK_LeftArrow),
            "RIGHT": UInt32(kVK_RightArrow),
            "RIGHTARROW": UInt32(kVK_RightArrow),
            "UP": UInt32(kVK_UpArrow),
            "UPARROW": UInt32(kVK_UpArrow),
            "DOWN": UInt32(kVK_DownArrow),
            "DOWNARROW": UInt32(kVK_DownArrow),
            "[": UInt32(kVK_ANSI_LeftBracket),
            "]": UInt32(kVK_ANSI_RightBracket),
            ",": UInt32(kVK_ANSI_Comma),
            ".": UInt32(kVK_ANSI_Period)
        ]
        let functionKeys: [(String, Int)] = [
            ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4),
            ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7), ("F8", kVK_F8),
            ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12)
        ]
        for (name, code) in functionKeys {
            map[name] = UInt32(code)
        }
        return map
    }()
}
