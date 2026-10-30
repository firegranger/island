import AppKit
import SwiftUI

/// Fenêtre transparente posée sur l'encoche, au-dessus de la barre des menus.
final class IslandPanel: NSPanel {
    var onRightClick: ((NSEvent) -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // L'îlot ne vole jamais le focus clavier à l'app active.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Sans ça, macOS repousse la fenêtre sous la barre des menus.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown where onRightClick != nil:
            onRightClick?(event)
        case .scrollWheel where onScroll != nil:
            onScroll?(event)
        default:
            super.sendEvent(event)
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Place la fenêtre, laisse passer les clics hors de l'îlot, gère le survol et le glisser à deux doigts.
final class IslandController {
    var menuProvider: (() -> NSMenu)?

    private let model: IslandModel
    private let panel = IslandPanel()
    private let scanner = MenuBarScanner()
    private var screenTop: CGFloat = 0
    private var centerX: CGFloat = 0
    private var hoverZone = NSRect.zero
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var pendingHover: Bool?
    private var swipeDistance: CGFloat = 0
    private var swipeDone = false
    private var cursorHidden = false
    private var cursorWatch: Timer?
    private var menuOpen = false

    init(model: IslandModel) {
        self.model = model
        Self.allowCursorInBackground()

        let host = FirstMouseHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.onRightClick = { [weak self] event in
            guard let self, let menu = menuProvider?(), let view = panel.contentView else { return }
            // Le menu a besoin du curseur, même s'il s'ouvre dans l'encoche.
            menuOpen = true
            setCursorHidden(false)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            menuOpen = false
        }
        panel.onScroll = { [weak self] event in self?.scrolled(event) }

        scanner.onChange = { [weak model] space in model?.space = space }
        layout()
        scanner.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            monitors.append(local)
        }

        observeGeometry()
    }

    // MARK: - Placement

    private func layout() {
        guard let screen = NSScreen.screens.first(where: Self.showsNotch),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            // Aucune encoche visible : Island se met en retrait jusqu'à ce qu'elle réapparaisse.
            panel.orderOut(nil)
            model.isAvailable = false
            model.hovering = false
            setCursorHidden(false)
            scanner.notch = .zero
            return
        }
        let frame = screen.frame
        var metrics = IslandMetrics()
        metrics.notchWidth = frame.width - left.width - right.width
        metrics.notchHeight = screen.safeAreaInsets.top
        centerX = frame.minX + left.width + metrics.notchWidth / 2
        hoverZone = NSRect(x: centerX - metrics.notchWidth / 2, y: frame.maxY - metrics.notchHeight,
                           width: metrics.notchWidth, height: metrics.notchHeight + 1)
        screenTop = frame.maxY
        model.metrics = metrics

        // Le scanner travaille en coordonnées Accessibilité (origine en haut à gauche de l'écran principal).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        scanner.screen = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        scanner.notch = CGRect(x: centerX - metrics.notchWidth / 2, y: primaryHeight - frame.maxY,
                               width: metrics.notchWidth, height: metrics.notchHeight)

        let size = metrics.windowSize
        panel.setFrame(NSRect(x: centerX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        model.isAvailable = true
        panel.orderFrontRegardless()
    }

    /// Écran qui montre vraiment son encoche : ni dans une définition qui la cache (16:9…),
    /// ni en recopie vidéo, où l'îlot apparaîtrait aussi sur l'autre écran, qui n'en a pas.
    private static func showsNotch(_ screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsInMirrorSet(id) == 0
    }

    // MARK: - Souris

    /// Rectangle occupé par l'îlot, en coordonnées écran.
    private var islandRect: NSRect {
        let metrics = model.metrics
        let geometry = model.displayedGeometry
        let height = max(0, metrics.notchHeight + geometry.below)
        return NSRect(x: centerX - metrics.notchWidth / 2 - geometry.left, y: screenTop - height,
                      width: metrics.notchWidth + geometry.left + geometry.right, height: height)
    }

    private func mouseMoved() {
        guard model.isAvailable else { return }
        let point = NSEvent.mouseLocation
        let overIsland = hoverZone.contains(point) || islandRect.contains(point)

        // Hors de l'îlot, les clics traversent la fenêtre.
        panel.ignoresMouseEvents = !overIsland
        setHovering(overIsland)
        updateCursor(at: point)
    }

    private func setHovering(_ value: Bool) {
        if value == model.hovering {
            hoverWork?.cancel()
            hoverWork = nil
            pendingHover = nil
            return
        }
        guard pendingHover != value else { return }
        hoverWork?.cancel()
        pendingHover = value
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingHover = nil
            model.hovering = value
            if value && model.isInteractive {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (value ? 0.05 : 0.25), execute: work)
    }

    // L'îlot change de forme sous une souris immobile : on recalcule les zones cliquables.
    private func observeGeometry() {
        withObservationTracking {
            _ = model.displayedGeometry
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.mouseMoved()
                self?.observeGeometry()
            }
        }
    }

    // MARK: - Curseur

    /// Comme derrière une vraie encoche, le curseur disparaît entièrement dès qu'il y entre.
    private func updateCursor(at point: NSPoint) {
        setCursorHidden(model.isAvailable && !menuOpen && hoverZone.contains(point))
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden {
            CGDisplayHideCursor(CGMainDisplayID())
            // Filet de sécurité : si un mouvement nous échappe (menu ouvert…), le curseur revient quand même.
            let watch = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateCursor(at: NSEvent.mouseLocation)
            }
            RunLoop.main.add(watch, forMode: .common)
            cursorWatch = watch
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorWatch?.invalidate()
            cursorWatch = nil
        }
    }

    /// Une app en arrière-plan ne peut pas masquer le curseur ; ce réglage privé du WindowServer l'y autorise.
    private static func allowCursorInBackground() {
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let connection = dlsym(handle, "CGSMainConnectionID").map({ unsafeBitCast($0, to: ConnectionFn.self) }),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty").map({ unsafeBitCast($0, to: SetPropertyFn.self) })
        else {
            log.error("Curseur : impossible de le masquer en arrière-plan")
            return
        }
        let id = connection()
        _ = setProperty(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    // MARK: - Glisser à deux doigts

    /// Doigts vers la gauche : morceau suivant ; vers la droite : précédent.
    private func scrolled(_ event: NSEvent) {
        guard model.media.hasMedia, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            swipeDistance = 0
            swipeDone = false
        }
        if event.phase.contains(.changed), abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            // Sens réel des doigts, quel que soit le réglage « défilement naturel ».
            swipeDistance += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            if !swipeDone && abs(swipeDistance) > 50 {
                swipeDone = true
                model.skip(forward: swipeDistance < 0)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            // Le contenu suit les doigts avec une résistance, puis revient en place.
            model.swipeOffset = swipeDone ? 0 : 12 * tanh(swipeDistance / 60)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            model.swipeOffset = 0
        }
    }
}
