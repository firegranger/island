import AppKit

/// Place libre (en points) de part et d'autre de l'encoche dans la barre des menus.
struct MenuBarSpace: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
}

/// Mesure, via l'Accessibilité, où s'arrêtent les menus de l'app active (à gauche)
/// et où commencent les icônes d'état (à droite), pour que l'îlot ne les recouvre jamais.
final class MenuBarScanner {
    var onChange: ((MenuBarSpace) -> Void)?
    /// Encoche et écran qui la porte, en coordonnées Accessibilité (origine en haut à gauche de l'écran principal).
    var notch: CGRect = .zero { didSet { if notch != oldValue { scan() } } }
    var screen: CGRect = .zero

    /// Écart minimal gardé avec les menus et les icônes.
    private static let margin: CGFloat = 12
    private let queue = DispatchQueue(label: "com.antho.island.menubar", qos: .utility)
    private var timer: Timer?
    private var statusOwners: [pid_t] = []
    private var lastFullScan = Date.distantPast
    private var space = MenuBarSpace()

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name != NSWorkspace.didActivateApplicationNotification { self?.lastFullScan = .distantPast }
                self?.scan()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 1
        scan()
    }

    func scan() {
        guard AXIsProcessTrusted(), notch.width > 0 else { return }
        let notch = self.notch
        // Avec plusieurs écrans, seuls comptent les éléments de la barre de l'écran à encoche.
        let screen = self.screen
        func onNotchBar(_ frame: CGRect) -> Bool {
            abs(frame.minY - notch.minY) < 4 && frame.width > 0 && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // De temps en temps (et tant qu'on ne connaît aucune icône), on repasse toutes les apps.
        let fullScan = statusOwners.isEmpty || Date().timeIntervalSince(lastFullScan) > 15
        let candidates = fullScan ? NSWorkspace.shared.runningApplications.map(\.processIdentifier) : statusOwners
        if fullScan { lastFullScan = Date() }

        queue.async { [weak self] in
            // Menus de l'app active. Quand ils sont trop nombreux, macOS en place aussi à droite de l'encoche.
            let menus = frontmost.flatMap { Self.frames(of: $0, bar: kAXMenuBarAttribute) }?
                .filter(onNotchBar)
            let menusEnd = menus?.filter { $0.midX < notch.midX }.map(\.maxX).max()
            var rightStart = menus?.filter { $0.midX >= notch.midX }.map(\.minX).min() ?? .infinity

            // Icônes d'état, à droite.
            var owners: [pid_t] = []
            for pid in candidates {
                guard let frames = Self.frames(of: pid, bar: "AXExtrasMenuBar") else { continue }
                owners.append(pid)
                for frame in frames where onNotchBar(frame) && frame.maxX > notch.midX {
                    rightStart = min(rightStart, frame.minX)
                }
            }

            // Sans information fiable, on considère qu'il n'y a pas de place.
            let space = menus == nil ? MenuBarSpace() : MenuBarSpace(
                left: menusEnd.map { max(0, notch.minX - $0 - Self.margin) } ?? 0,
                right: rightStart.isFinite ? max(0, rightStart - notch.maxX - Self.margin) : 0)

            DispatchQueue.main.async {
                guard let self else { return }
                if fullScan { self.statusOwners = owners }
                guard space != self.space else { return }
                self.space = space
                log.notice("Barre des menus : \(Int(space.left)) pt libres à gauche, \(Int(space.right)) pt à droite")
                self.onChange?(space)
            }
        }
    }

    /// Cadres des éléments d'une barre (menus ou icônes d'état) d'une app.
    private static func frames(of pid: pid_t, bar attribute: String) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.compactMap(frame(of:))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
