import AppKit

struct DisplayDescriptor: Equatable, Identifiable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var scaleFactor: CGFloat
}

protocol DisplayManager {
    func displays() -> [DisplayDescriptor]
    func activeDisplay() -> DisplayDescriptor?
}

final class SystemDisplayManager: DisplayManager {
    func displays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return DisplayDescriptor(
                id: CGDirectDisplayID(number.uint32Value),
                frame: screen.frame,
                scaleFactor: screen.backingScaleFactor
            )
        }
    }

    func activeDisplay() -> DisplayDescriptor? {
        let cursor = NSEvent.mouseLocation
        return displays().first { $0.frame.contains(cursor) } ?? displays().first
    }
}