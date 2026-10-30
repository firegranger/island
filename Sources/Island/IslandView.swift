import SwiftUI

/// Rythme commun à toutes les animations de l'îlot.
enum Motion {
    /// Changement de forme : ressort légèrement rebondissant, comme sur iPhone.
    static let morph = Animation.spring(duration: 0.5, bounce: 0.24)
    /// Gonflement au survol : plus court et plus élastique, comme un retour haptique.
    static let bump = Animation.spring(duration: 0.32, bounce: 0.45)
    /// Le contenu apparaît une fois que la forme a commencé à s'ouvrir…
    static let contentIn = Animation.easeOut(duration: 0.26).delay(0.1)
    /// … et s'efface avant qu'elle se referme.
    static let contentOut = Animation.easeIn(duration: 0.12)
    static let swipe = Animation.interactiveSpring(response: 0.25, dampingFraction: 0.8)
    static let value = Animation.smooth(duration: 0.18)
}

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let metrics = model.metrics
        let presentation = model.presentation
        let shape = IslandShape(metrics: metrics, geometry: model.displayedGeometry)
        let size = metrics.windowSize

        ZStack(alignment: .topLeading) {
            shape.fill(.black)
            content(presentation, IslandLayout(metrics: metrics))
                .offset(x: model.swipeOffset)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.tap() }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(Motion.morph, value: model.geometry(for: presentation))
        .animation(Motion.bump, value: model.hovering)
        .animation(Motion.swipe, value: model.swipeOffset)
    }

    @ViewBuilder
    private func content(_ presentation: Presentation, _ layout: IslandLayout) -> some View {
        switch presentation {
        case .idle:
            EmptyView()
        case .music:
            let placement = model.placement(for: .music)
            MusicContent(media: model.media, spectrum: model.spectrum, placement: placement, layout: layout,
                         showsTitle: model.showsTrackTitle, forward: model.skippedForward)
                .id(placement.kind)
                .transition(.island)
        case .hud:
            if let hud = model.hud {
                let placement = model.placement(for: .hud)
                HUDContent(hud: hud, placement: placement, layout: layout)
                    .id(placement.kind)
                    .transition(.island)
            }
        case .notification:
            if let banner = model.banner {
                BannerContent(banner: banner, layout: layout)
                    .id(banner.id)
                    .transition(.island)
            }
        }
    }
}

// MARK: - Forme et mise en place

/// Prolonge l'encoche : ailes dans la barre des menus, hauteur dessous, coins bas arrondis façon Apple.
/// Comme l'encoche, ses bords s'évasent en haut pour rejoindre le bord de l'écran en courbe tangente.
/// Toutes ses dimensions s'animent.
struct IslandShape: Shape {
    var metrics: IslandMetrics
    var geometry: IslandGeometry

    /// Rayon des épaules de l'encoche, là où elle rejoint le haut de l'écran.
    static let shoulder: CGFloat = 6

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(geometry.left, geometry.right), AnimatablePair(geometry.below, geometry.radius)) }
        set {
            geometry.left = newValue.first.first
            geometry.right = newValue.first.second
            geometry.below = newValue.second.first
            geometry.radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let notchMinX = rect.midX - metrics.notchWidth / 2
        let top = rect.minY
        let frame = CGRect(x: notchMinX - geometry.left, y: top,
                           width: max(0, metrics.notchWidth + geometry.left + geometry.right),
                           height: max(0, metrics.notchHeight + geometry.below))
        let bottomRadius = min(geometry.radius, min(frame.width, frame.height) / 2)
        let body = UnevenRoundedRectangle(bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
                                          style: .continuous).path(in: frame)
        let shoulder = min(Self.shoulder, frame.height - bottomRadius)
        guard shoulder > 0, frame.width > 0 else { return body }

        // Chaque épaule déborde un peu dans le corps pour que l'union se fasse sans couture.
        var shoulders = Path()
        for (edge, outward) in [(frame.minX, -shoulder), (frame.maxX, shoulder)] {
            shoulders.move(to: CGPoint(x: edge + outward, y: top))
            shoulders.addQuadCurve(to: CGPoint(x: edge, y: top + shoulder), control: CGPoint(x: edge, y: top))
            shoulders.addLine(to: CGPoint(x: edge - outward, y: top + shoulder))
            shoulders.addLine(to: CGPoint(x: edge - outward, y: top))
            shoulders.closeSubpath()
        }
        return body.union(shoulders)
    }
}

/// Zones de l'îlot en coordonnées de la fenêtre, dont l'encoche occupe le centre.
struct IslandLayout {
    let metrics: IslandMetrics

    private var notchMinX: CGFloat { (metrics.windowSize.width - metrics.notchWidth) / 2 }

    func left(_ width: CGFloat) -> CGRect {
        CGRect(x: notchMinX - width, y: 0, width: width, height: metrics.notchHeight)
    }

    func right(_ width: CGFloat) -> CGRect {
        CGRect(x: notchMinX + metrics.notchWidth, y: 0, width: width, height: metrics.notchHeight)
    }

    func below(_ height: CGFloat) -> CGRect {
        CGRect(x: notchMinX, y: metrics.notchHeight, width: metrics.notchWidth, height: height)
    }

    /// Sous l'encoche et ses ailes, sur toute la largeur de l'îlot.
    func under(left: CGFloat, right: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: notchMinX - left, y: metrics.notchHeight, width: metrics.notchWidth + left + right, height: height)
    }
}

private extension View {
    func placed(in rect: CGRect, alignment: Alignment = .center) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .position(x: rect.midX, y: rect.midY)
    }

    /// Remplit la fenêtre pour que `placed(in:)` travaille dans ses coordonnées.
    func windowSized(_ layout: IslandLayout) -> some View {
        frame(width: layout.metrics.windowSize.width, height: layout.metrics.windowSize.height)
    }
}

private extension AnyTransition {
    /// Le contenu se forme dans le flou en sortant de l'encoche, et s'y résorbe.
    static var island: AnyTransition {
        let blur = AnyTransition.modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
        return .asymmetric(insertion: blur.animation(Motion.contentIn), removal: blur.animation(Motion.contentOut))
    }
}

private struct BlurFade: ViewModifier {
    var amount: Double
    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * amount)
            .opacity(1 - amount)
            .scaleEffect(1 - 0.08 * amount, anchor: .top)
    }
}

// MARK: - Musique

private struct MusicContent: View {
    let media: NowPlaying
    let spectrum: AudioSpectrum
    let placement: Placement
    let layout: IslandLayout
    let showsTitle: Bool
    let forward: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !media.isPlaying)) { context in
            let date = context.date
            ZStack {
                switch placement {
                case .wings(let width):
                    // Comme sur iPhone : pochette à gauche de l'encoche, onde à droite.
                    track { artwork }
                        .placed(in: layout.left(width))
                    spectrumView(date)
                        .placed(in: layout.right(width))
                    if showsTitle {
                        trackTitle(date)
                            .placed(in: layout.under(left: width, right: width, height: 40))
                            .transition(.island)
                    }

                case .right(let width):
                    HStack(spacing: 9) {
                        track { artwork }
                        spectrumView(date)
                    }
                    .placed(in: layout.right(width))
                    if showsTitle {
                        trackTitle(date)
                            .placed(in: layout.under(left: 0, right: width, height: 40))
                            .transition(.island)
                    }

                case .below:
                    HStack(spacing: 8) {
                        track {
                            Marquee(text: media.title, secondary: media.artist, startedAt: media.titleChangedAt, date: date)
                        }
                        spectrumView(date)
                    }
                    .padding(.horizontal, 14)
                    .placed(in: layout.below(22))
                }
            }
            .windowSized(layout)
            .animation(Motion.morph, value: media.title)
        }
    }

    private var artwork: some View {
        Artwork(image: media.artwork, size: 20, radius: 5)
    }

    /// Titre et artiste, sous l'encoche, juste après un changement de morceau.
    private func trackTitle(_ date: Date) -> some View {
        track {
            VStack(spacing: 1) {
                Marquee(text: media.title, size: 12, centered: true, startedAt: media.titleChangedAt, date: date)
                Marquee(text: media.artist, size: 11, weight: .regular, centered: true, startedAt: media.titleChangedAt, date: date)
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// Ce qui dépend du morceau glisse dans le sens du changement de piste.
    private func track<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            content()
                .id(media.title + "\u{1F}" + media.artist)
                .transition(.push(from: forward ? .trailing : .leading))
        }
        .clipped()
    }

    private func spectrumView(_ date: Date) -> some View {
        Spectrum(date: date, playing: media.isPlaying, color: media.accent,
                 levels: spectrum.hasSignal ? spectrum.levels : nil)
    }
}

/// Texte sur une ligne. S'il est trop long, il défile une fois puis se fige, avec un fondu en bout.
private struct Marquee: View {
    let text: String
    var secondary: String? = nil
    var size: CGFloat = 11
    var weight: NSFont.Weight = .semibold
    var centered = false
    let startedAt: Date
    let date: Date

    private static let gap: CGFloat = 30
    private static let speed: Double = 26 // points par seconde

    var body: some View {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let secondaryFont = NSFont.systemFont(ofSize: size, weight: .regular)
        let secondaryText = secondary.map { "  " + $0 } ?? ""
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width
            + (secondaryText as NSString).size(withAttributes: [.font: secondaryFont]).width)

        GeometryReader { geo in
            let overflows = textWidth > geo.size.width
            let distance = textWidth + Self.gap
            let scrolled = overflows ? min(CGFloat(max(0, date.timeIntervalSince(startedAt) - 1.5) * Self.speed), distance) : 0
            let scrolling = scrolled > 0 && scrolled < distance
            let label = Text(text).font(Font(font as CTFont))
                + Text(secondaryText).font(Font(secondaryFont as CTFont)).foregroundColor(.white.opacity(0.55))

            HStack(spacing: Self.gap) {
                label
                if overflows { label }
            }
            .lineLimit(1)
            .fixedSize()
            .offset(x: -scrolled)
            .frame(width: geo.size.width, height: geo.size.height, alignment: centered && !overflows ? .center : .leading)
            .mask {
                LinearGradient(stops: [
                    .init(color: scrolling ? .clear : .black, location: 0),
                    .init(color: .black, location: overflows ? 0.1 : 0),
                    .init(color: .black, location: overflows ? 0.82 : 1),
                    .init(color: overflows ? .clear : .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
        .frame(height: ceil(size * 1.3))
    }
}

/// Petit spectre teinté par la pochette : le vrai son si la capture est autorisée,
/// sinon une animation en rythme.
private struct Spectrum: View {
    let date: Date
    let playing: Bool
    let color: Color
    let levels: [Float]?

    private static let speeds = [3.1, 4.7, 3.7, 5.3, 2.9]
    private static let phases = [0.0, 1.3, 2.1, 0.7, 2.9]

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        let beat = 0.62 + 0.38 * abs(sin(t * .pi * 2)) // ≈ 120 bpm
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                let level = levels.map { 0.18 + 0.82 * Double($0[i]) }
                    ?? (playing ? 0.18 + 0.82 * abs(sin(t * Self.speeds[i] + Self.phases[i])) * beat : 0.18)
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: max(2, 11 * level))
            }
        }
        .frame(height: 11)
    }
}

private struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Volume / luminosité

private struct HUDContent: View {
    let hud: HUD
    let placement: Placement
    let layout: IslandLayout

    var body: some View {
        ZStack {
            switch placement {
            case .wings(let width):
                // Icône à gauche de l'encoche, niveau à droite.
                icon
                    .padding(.leading, 14)
                    .placed(in: layout.left(width), alignment: .leading)
                Bar(value: level)
                    .frame(height: 4)
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .placed(in: layout.right(width))
            case .right(let width):
                row.padding(.leading, 12).padding(.trailing, 14).placed(in: layout.right(width))
            case .below:
                row.padding(.horizontal, 14).placed(in: layout.below(22))
            }
        }
        .windowSized(layout)
    }

    private var level: Double { hud.muted ? 0 : hud.value }

    private var icon: some View {
        Image(systemName: hud.symbol)
            .font(.system(size: 11, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 18)
    }

    private var row: some View {
        HStack(spacing: 8) {
            icon
            Bar(value: level).frame(height: 4)
        }
    }
}

private struct Bar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: geo.size.width * min(1, max(0, value)))
                }
        }
        .animation(Motion.value, value: value)
    }
}

// MARK: - Notifications

private struct BannerContent: View {
    let banner: Banner
    let layout: IslandLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let icon = banner.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(banner.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            if !banner.body.isEmpty {
                Text(banner.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .placed(in: layout.below(68), alignment: .topLeading)
        .windowSized(layout)
    }
}
