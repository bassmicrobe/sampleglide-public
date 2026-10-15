import AppKit
import SwiftUI

/// NSTableView consumes horizontal arrows before SwiftUI's onMoveCommand.
/// Route plain arrows while a browser column owns focus, leaving text fields,
/// sheets, sliders and other controls to their native keyboard behavior.
struct FolderHierarchyKeyboardView: NSViewRepresentable {
    let action: (MoveCommandDirection) -> Bool

    final class Coordinator {
        var monitor: Any?
        var action: (MoveCommandDirection) -> Bool
        init(action: @escaping (MoveCommandDirection) -> Bool) { self.action = action }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator = context.coordinator] event in
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let window = view?.window, event.window === window, window.attachedSheet == nil else { return event }
            let responder = window.firstResponder
            if responder is NSTextView || responder is NSTextField { return event }
            if responder is NSControl && !(responder is NSTableView) { return event }
            let direction: MoveCommandDirection
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: return event
            }
            return coordinator?.action(direction) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}
