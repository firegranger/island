import AppKit
import Observation

/// Ce que l'îlot affiche. Un seul état à la fois, par ordre de priorité.
enum Presentation: Equatable {
    case idle, music, hud, notification
}

/// Où va le contenu compact (musique, volume) : de part et d'autre de l'encoche
/// si la barre des menus a de la place, sinon à droite seulement, sinon dessous.
enum Placement: Equatable {
    case wings(CGFloat) // largeur de chaque aile
    case right(CGFloat)
    case below

    /// Sans la largeur : sert d'identité aux contenus (une simple variation de largeur ne les remplace pas).
    var kind: Int {
        switch self {
        case .wings: return 0
        case .right: return 1
        case .below: return 2
        }
    }
}

/// Forme de l'îlot autour de l'encoche : ailes gauche/droite dans la barre des menus,
/// hauteur ajoutée sous l'encoche, rayon des coins bas.
struct IslandGeometry: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var below: CGFloat = 0
    var radius: CGFloat = 12
}

struct HUD: Equatable {
    enum Kind { case volume, brightness }
    var kind: Kind
    var value: Double
    var muted = false

    var symbol: String {
        switch kind {
        case .brightness:
            return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || value == 0 { return "speaker.slash.fill" }
            return value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

struct Banner: Equatable {
    let id = UUID()
    var title: String
    var body: String
    var bundleID: String?
    var icon: NSImage?

    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

struct IslandMetrics: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32

    static let maxWing: CGFloat = 210
    var windowSize: CGSize { CGSize(width: notchWidth + 2 * Self.maxWing, height: notchHeight + 90) }
}

@Observable
final class IslandModel {
    var metrics = IslandMetrics()
    /// Faux quand aucune encoche n'est visible (Mac fermé, recopie vers un projecteur…) : Island se met en retrait.
    var isAvailable = true {
        didSet {
            guard isAvailable != oldValue else { return }
            log.notice("\(self.isAvailable ? "Encoche visible : îlot affiché" : "Aucune encoche visible : îlot masqué")")
            updateSpectrum()
        }
    }
    var space = MenuBarSpace()
    var hud: HUD?
    var banner: Banner?
    var hovering = false
    /// Décalage du contenu qui suit les doigts pendant un glisser.
    var swipeOffset: CGFloat = 0
    /// Sens du dernier changement de morceau (pour l'animation du titre).
    var skippedForward = true
    /// Titre et artiste affichés quelques secondes sous l'encoche après un changement de morceau.
    var showsTrackTitle = false
    let media = NowPlaying()
    let spectrum = AudioSpectrum()

    init() {
        media.onTrackChange = { [weak self] in self?.showTrackTitle() }
        media.onActiveChange = { [weak self] _ in self?.updateSpectrum() }
    }

    /// Le spectre n'écoute le son que pendant la lecture, et seulement si l'îlot est visible.
    private func updateSpectrum() {
        if isAvailable && media.isActive { spectrum.start() } else { spectrum.stop() }
    }

    var presentation: Presentation {
        if hud != nil { return .hud }
        if banner != nil { return .notification }
        if media.hasMedia && (media.isActive || showsTrackTitle) { return .music }
        return .idle
    }

    /// Le survol ne fait réagir l'îlot que s'il y a quelque chose à faire.
    var isInteractive: Bool { media.hasMedia || banner != nil }

    func placement(for presentation: Presentation) -> Placement {
        // Largeurs d'aile acceptables : (minimum, maximum). La musique ne montre que pochette et onde.
        let (wings, right): ((CGFloat, CGFloat), (CGFloat, CGFloat)) = presentation == .hud ? ((64, 84), (120, 150)) : ((36, 40), (60, 64))
        let both = min(space.left, space.right)
        if both >= wings.0 { return .wings(min(both, wings.1)) }
        if space.right >= right.0 { return .right(min(space.right, right.1)) }
        return .below
    }

    /// Forme visée pour un état, sans l'effet de survol.
    func geometry(for presentation: Presentation) -> IslandGeometry {
        switch presentation {
        case .idle:
            // Légèrement plus petit que l'encoche, épaules comprises : entièrement caché derrière elle.
            return IslandGeometry(left: -3, right: -3, below: -4, radius: 10)
        case .notification:
            return IslandGeometry(below: 68, radius: 18)
        case .music, .hud:
            // Après un changement de morceau, l'îlot descend pour montrer titre et artiste.
            let title = presentation == .music && showsTrackTitle
            let below: CGFloat = title ? 40 : 0
            let radius: CGFloat = title ? 18 : 12
            switch placement(for: presentation) {
            case .wings(let width): return IslandGeometry(left: width, right: width, below: below, radius: radius)
            case .right(let width): return IslandGeometry(right: width, below: below, radius: radius)
            case .below: return IslandGeometry(below: 22)
            }
        }
    }

    /// Forme affichée : au survol, l'îlot gonfle très légèrement, comme un retour haptique.
    var displayedGeometry: IslandGeometry {
        var geometry = geometry(for: presentation)
        guard hovering && isInteractive else { return geometry }
        if presentation == .idle {
            return IslandGeometry(left: 4, right: 4, below: 5, radius: 12)
        }
        geometry.left += geometry.left > 0 ? 3 : 0
        geometry.right += geometry.right > 0 ? 3 : 0
        geometry.below += 3
        return geometry
    }

    @ObservationIgnored private var hudTimer: DispatchWorkItem?
    @ObservationIgnored private var bannerTimer: DispatchWorkItem?
    @ObservationIgnored private var titleTimer: DispatchWorkItem?

    func show(_ hud: HUD) {
        self.hud = hud
        schedule(&hudTimer, after: 1.5) { [weak self] in self?.hud = nil }
    }

    func show(_ banner: Banner) {
        self.banner = banner
        scheduleBannerDismissal(after: 5)
    }

    /// Clic sur l'îlot : ouvre l'app de la notification, sinon lecture/pause.
    func tap() {
        if let id = banner?.bundleID {
            openApp(id)
            banner = nil
        } else if media.hasMedia {
            media.togglePlayPause()
        }
    }

    func skip(forward: Bool) {
        skippedForward = forward
        if forward { media.next() } else { media.previous() }
        showTrackTitle()
    }

    func showTrackTitle() {
        showsTrackTitle = true
        schedule(&titleTimer, after: 4) { [weak self] in self?.showsTrackTitle = false }
    }

    func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // La notification reste affichée tant que la souris est dessus.
    private func scheduleBannerDismissal(after delay: TimeInterval) {
        schedule(&bannerTimer, after: delay) { [weak self] in
            guard let self else { return }
            if hovering { scheduleBannerDismissal(after: 1.5) } else { banner = nil }
        }
    }

    private func schedule(_ timer: inout DispatchWorkItem?, after delay: TimeInterval, _ action: @escaping () -> Void) {
        timer?.cancel()
        let work = DispatchWorkItem(block: action)
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
