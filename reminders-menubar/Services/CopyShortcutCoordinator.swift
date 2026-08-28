import AppKit

struct CopyShortcutModifiers: OptionSet {
    let rawValue: UInt

    static let command = CopyShortcutModifiers(rawValue: 1 << 0)
    static let shift = CopyShortcutModifiers(rawValue: 1 << 1)
    static let option = CopyShortcutModifiers(rawValue: 1 << 2)
    static let control = CopyShortcutModifiers(rawValue: 1 << 3)
    static let capsLock = CopyShortcutModifiers(rawValue: 1 << 4)
    static let numericPad = CopyShortcutModifiers(rawValue: 1 << 5)
    static let function = CopyShortcutModifiers(rawValue: 1 << 6)
    static let deviceSpecific = CopyShortcutModifiers(rawValue: 1 << 7)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: CopyShortcutModifiers = []
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if eventFlags.contains(.numericPad) { modifiers.insert(.numericPad) }
        if eventFlags.contains(.function) { modifiers.insert(.function) }

        let knownFlags: NSEvent.ModifierFlags = [
            .command, .shift, .option, .control, .capsLock, .numericPad, .function, .help
        ]
        if !eventFlags.subtracting(knownFlags).isEmpty {
            modifiers.insert(.deviceSpecific)
        }
        self = modifiers
    }
}

struct CopyShortcutEventDescription {
    let charactersIgnoringModifiers: String?
    let modifiers: CopyShortcutModifiers

    init(charactersIgnoringModifiers: String?, modifiers: CopyShortcutModifiers) {
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: CopyShortcutModifiers(eventFlags: event.modifierFlags)
        )
    }

    var isUnmodifiedCommandC: Bool {
        guard modifiers.contains(.command),
              modifiers.intersection([.shift, .option, .control]).isEmpty else {
            return false
        }
        return charactersIgnoringModifiers?.lowercased() == "c"
    }
}

enum CopyShortcutResponderState: Equatable {
    case none
    case editableOrSelectableText
}

enum CopyShortcutRoutingResult: Equatable {
    case passThrough
    case consume
}

@MainActor
final class CopyShortcutCoordinator: ObservableObject {
    struct HoverRegistration: Hashable {
        fileprivate let id = UUID()
        let reminderId: String
    }

    private var monitor: Any?
    private var hoveredRegistration: HoverRegistration?
    private var copyActions: [HoverRegistration: () -> Bool] = [:]
    private var presentedSurfaceIdentifiers: Set<UUID> = []

    init(installMonitor: Bool = true) {
        if installMonitor {
            self.installMonitor()
        }
    }

    func registerCopyAction(
        reminderId: String,
        copyAction: @escaping () -> Bool
    ) -> HoverRegistration {
        let registration = HoverRegistration(reminderId: reminderId)
        copyActions[registration] = copyAction
        return registration
    }

    func updateCopyAction(
        _ registration: HoverRegistration,
        copyAction: @escaping () -> Bool
    ) {
        guard copyActions[registration] != nil else { return }
        copyActions[registration] = copyAction
    }

    func setHovered(_ registration: HoverRegistration) {
        hoveredRegistration = registration
    }

    func clearIfCurrent(_ registration: HoverRegistration) {
        guard hoveredRegistration == registration else { return }
        hoveredRegistration = nil
    }

    func unregisterCopyAction(_ registration: HoverRegistration) {
        copyActions[registration] = nil
        // Keep the hovered registration until its matching hover-exit arrives. In the
        // meantime it is intentionally stale and must never fall back to another row.
    }

    func setSurfacePresented(_ isPresented: Bool, id: UUID) {
        if isPresented {
            presentedSurfaceIdentifiers.insert(id)
        } else {
            presentedSurfaceIdentifiers.remove(id)
        }
    }

    func route(
        _ event: CopyShortcutEventDescription,
        responderState: CopyShortcutResponderState
    ) -> CopyShortcutRoutingResult {
        guard event.isUnmodifiedCommandC,
              responderState != .editableOrSelectableText,
              presentedSurfaceIdentifiers.isEmpty,
              let hoveredRegistration,
              let copyAction = copyActions[hoveredRegistration],
              copyAction() else {
            return .passThrough
        }
        return .consume
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
                let responderState = Self.responderState(for: responder)
                return self.route(
                    CopyShortcutEventDescription(event: event),
                    responderState: responderState
                ) == .consume
            }

            return handled ? nil : event
        }
    }

    private static func responderState(for responder: NSResponder?) -> CopyShortcutResponderState {
        if let text = responder as? NSText, text.isEditable || text.isSelectable {
            return .editableOrSelectableText
        }
        if let textField = responder as? NSTextField,
           textField.isEditable || textField.isSelectable {
            return .editableOrSelectableText
        }
        return .none
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
