import AppKit
import Observation
import SwiftUI

/// Musique en cours, toutes apps confondues (Musique, Spotify, navigateurs…).
/// Les données viennent du pont MediaRemote lancé via /usr/bin/perl (voir Bridge/).
@Observable
final class NowPlaying {
    var title = ""
    var artist = ""
    var artwork: NSImage?
    var accent = Color.white
    var bundleID: String?
    var isPlaying = false {
        didSet { updateActivity() }
    }
    /// Vrai tant que la musique joue, et encore quelques secondes après la pause.
    var isActive = false {
        didSet { if isActive != oldValue { onActiveChange?(isActive) } }
    }
    /// Moment où le titre a changé : le titre défile une fois s'il est trop long.
    var titleChangedAt = Date()

    var hasMedia: Bool { !title.isEmpty }

    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored var onTrackChange: (() -> Void)?
    @ObservationIgnored private var receivedFirstUpdate = false
    @ObservationIgnored private var idleWork: DispatchWorkItem?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var stopped = false

    // On garde l'îlot quelques secondes après la pause (et pendant les changements de piste).
    private func updateActivity() {
        idleWork?.cancel()
        if isPlaying && hasMedia {
            isActive = true
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.isActive = false }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - Commandes

    func togglePlayPause() {
        isPlaying.toggle()
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    private func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - Pont

    func start() {
        guard let script = Bundle.main.url(forResource: "bridge", withExtension: "pl"),
              let library = Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "dylib") else {
            log.error("Pont musique absent du bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeDidExit() }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            buffer.removeAll()
            log.notice("Pont musique lancé")
        } catch {
            log.error("Pont musique : \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    private func bridgeDidExit() {
        process = nil
        input = nil
        guard !stopped else { return }
        failures += 1
        guard failures < 5 else {
            log.error("Pont musique abandonné après plusieurs échecs")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(json)
            }
        }
    }

    private func apply(_ json: [String: Any]) {
        failures = 0
        let newTitle = json["title"] as? String ?? ""
        let newArtist = json["artist"] as? String ?? ""
        let trackChanged = newTitle != title || newArtist != artist
        if trackChanged { titleChangedAt = Date() }

        title = newTitle
        artist = newArtist
        bundleID = json["bundle"] as? String
        isPlaying = json["playing"] as? Bool ?? false

        if let encoded = json["artwork"] as? String {
            artwork = Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
            accent = artwork.map { Color(nsColor: Self.accentColor(of: $0)) } ?? .white
        }

        if trackChanged && receivedFirstUpdate && hasMedia { onTrackChange?() }
        receivedFirstUpdate = true
    }

    /// Couleur la plus vive de la pochette, éclaircie pour rester lisible sur fond noir.
    private static func accentColor(of image: NSImage) -> NSColor {
        let size = 12
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return .white }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var best = NSColor.white
        var bestScore: CGFloat = -1
        for x in 0..<size {
            for y in 0..<size {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let score = color.saturationComponent * (0.3 + color.brightnessComponent)
                if score > bestScore { bestScore = score; best = color }
            }
        }
        return NSColor(hue: best.hueComponent, saturation: min(best.saturationComponent, 0.7),
                       brightness: max(best.brightnessComponent, 0.85), alpha: 1)
    }
}
