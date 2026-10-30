import Accelerate
import CoreAudio
import Observation

/// Spectre réel du son qui sort du Mac (Core Audio "process tap", macOS 14.2+).
/// Ne tourne que pendant la lecture. Nécessite l'autorisation « Enregistrement audio système » :
/// le son est analysé à la volée, jamais enregistré.
@Observable
final class AudioSpectrum {
    static let bandCount = 5

    /// Niveau de chaque bande, de 0 à 1 (graves → aigus).
    private(set) var levels = [Float](repeating: 0, count: bandCount)
    /// Vrai dès qu'un son non nul arrive : sans autorisation, macOS ne fournit que du silence.
    private(set) var hasSignal = false

    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var procID: AudioDeviceIOProcID?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.antho.island.spectrum", qos: .userInteractive)
    @ObservationIgnored private var analyzer: Analyzer?
    @ObservationIgnored private var outputListener: AudioObjectPropertyListenerBlock?

    var isRunning: Bool { procID != nil }

    func start() {
        guard !isRunning else { return }
        do {
            try startTap()
            log.notice("Spectre : capture démarrée")
        } catch {
            log.error("Spectre : \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        if let outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        outputListener = nil
        analyzer = nil
        levels = [Float](repeating: 0, count: Self.bandCount)
        hasSignal = false
    }

    // MARK: - Core Audio

    private struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) (\(status))" }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    private func startTap() throws {
        // Tap sur tout le son du système, sans le couper.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "création du tap")

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format), "format du tap")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw Failure(step: "format non géré", status: OSStatus(format.mFormatID))
        }

        // Un périphérique agrégé privé relie le tap à la sortie audio courante.
        guard let outputUID = Self.defaultOutputUID() else { throw Failure(step: "sortie audio", status: -1) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "périphérique agrégé")

        let analyzer = Analyzer(sampleRate: format.mSampleRate) { [weak self] levels, signal in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.levels = levels
                if signal && !self.hasSignal { self.hasSignal = true }
            }
        }
        self.analyzer = analyzer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            analyzer.process(input)
        }, "lecture audio")
        try check(AudioDeviceStart(aggregateID, procID), "démarrage")

        // Changement de sortie (AirPods, écran…) : on relance sur la nouvelle.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.stop()
            self.start()
        }
        outputListener = listener
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private static func defaultOutputUID() -> String? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

// MARK: - Analyse (FFT)

/// Mélange en mono, FFT de 1024 points ~30 fois par seconde, puis 5 bandes logarithmiques.
/// Appelé uniquement depuis la file audio.
private final class Analyzer {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    // Limites des bandes (Hz) : graves, bas-médiums, médiums, haut-médiums, aigus.
    private static let edges: [Double] = [40, 150, 400, 1_000, 2_500, 8_000]

    private let publish: ([Float], Bool) -> Void
    private let setup: FFTSetup
    private let window: [Float]
    private let bandBins: [Range<Int>]
    private let hop: Int

    private var ring = [Float](repeating: 0, count: size)
    private var writeIndex = 0
    private var sinceLast = 0
    private var levels = [Float](repeating: 0, count: AudioSpectrum.bandCount)
    private var peaks = [Float](repeating: -60, count: AudioSpectrum.bandCount)

    init(sampleRate: Double, publish: @escaping ([Float], Bool) -> Void) {
        self.publish = publish
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        self.window = window
        hop = max(256, Int(sampleRate / 30))

        let binWidth = sampleRate / Double(Self.size)
        let maxBin = Self.size / 2
        bandBins = (0..<AudioSpectrum.bandCount).map { band in
            let low = max(1, Int(Self.edges[band] / binWidth))
            let high = min(maxBin, max(low + 1, Int(Self.edges[band + 1] / binWidth)))
            return low..<high
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))

        for frame in 0..<frames {
            var sum: Float = 0
            var count = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = Int(buffer.mNumberChannels)
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                count += channels
            }
            ring[writeIndex] = count > 0 ? sum / Float(count) : 0
            writeIndex = (writeIndex + 1) % Self.size
        }

        sinceLast += frames
        if sinceLast >= hop {
            sinceLast = 0
            analyze()
        }
    }

    private func analyze() {
        // Les 1024 derniers échantillons, dans l'ordre, fenêtrés.
        var samples = [Float](repeating: 0, count: Self.size)
        let tail = Self.size - writeIndex
        samples.withUnsafeMutableBufferPointer { out in
            ring.withUnsafeBufferPointer { ring in
                out.baseAddress!.update(from: ring.baseAddress! + writeIndex, count: tail)
                (out.baseAddress! + tail).update(from: ring.baseAddress!, count: writeIndex)
            }
        }
        var peakSample: Float = 0
        vDSP_maxmgv(samples, 1, &peakSample, vDSP_Length(Self.size))
        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))

        let half = Self.size / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        for (band, bins) in bandBins.enumerated() {
            var energy: Float = 0
            magnitudes.withUnsafeBufferPointer {
                vDSP_meanv($0.baseAddress! + bins.lowerBound, 1, &energy, vDSP_Length(bins.count))
            }
            let decibels = 10 * log10(energy + 1e-12)
            // Gain automatique par bande : chaque barre bouge, quel que soit le volume.
            peaks[band] = max(peaks[band] - 0.25, decibels, -60)
            let target = min(1, max(0, 1 + (decibels - peaks[band]) / 24))
            // Montée rapide, descente plus douce.
            levels[band] += (target - levels[band]) * (target > levels[band] ? 0.7 : 0.25)
        }
        publish(levels, peakSample > 0)
    }
}
