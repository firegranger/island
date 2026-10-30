import AppKit
import AudioToolbox
import CoreAudio

enum MediaKey: Int {
    case volumeUp = 0      // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1    // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3
    case mute = 7          // NX_KEYTYPE_MUTE
}

/// Intercepte les touches volume / luminosité pour remplacer l'indicateur de macOS.
/// Nécessite l'autorisation Accessibilité.
final class MediaKeyTap {
    /// Renvoie `true` si la touche a été prise en charge (l'événement est alors absorbé).
    var handler: ((MediaKey, _ fine: Bool) -> Bool)?
    private(set) var isActive = false

    private var port: CFMachPort?
    private var waitTimer: Timer?
    private var consumed = Set<MediaKey>()

    func start() {
        guard !isActive else { return }
        if AXIsProcessTrusted() {
            install()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.install()
        }
    }

    private func install() {
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().process(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Impossible d'intercepter les touches")
            return
        }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isActive = true
        log.notice("Touches volume/luminosité interceptées")
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
              let key = MediaKey(rawValue: (ns.data1 & 0xFFFF_0000) >> 16) else { return pass }

        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        let modifiers = ns.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌥ seul : macOS ouvre les réglages Son / Moniteurs, on ne s'en mêle pas.
        if modifiers.contains(.option) && !modifiers.contains(.shift) { return pass }

        if isDown {
            guard handler?(key, modifiers.contains([.option, .shift])) == true else { return pass }
            consumed.insert(key)
            return nil
        }
        return consumed.remove(key) != nil ? nil : pass
    }
}

/// Applique les touches et affiche l'indicateur dans l'îlot.
final class SystemControls {
    private let model: IslandModel
    private let brightness = Brightness()
    private var volumeBeforeMute: Double?

    init(model: IslandModel) {
        self.model = model
    }

    func handle(_ key: MediaKey, fine: Bool) -> Bool {
        // Sans encoche visible, l'îlot est masqué : macOS affiche alors son propre indicateur.
        guard model.isAvailable else { return false }
        // 16 crans comme macOS, 64 avec ⌥⇧.
        let step = fine ? 1.0 / 64 : 1.0 / 16
        func stepped(_ value: Double, _ delta: Double) -> Double {
            min(1, max(0, (value / step).rounded() * step + delta))
        }

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let current = brightness.value else { return false }
            let value = stepped(current, key == .brightnessUp ? step : -step)
            brightness.animate(to: value)
            model.show(HUD(kind: .brightness, value: value))

        case .volumeUp, .volumeDown, .mute:
            guard let device = SystemVolume.outputDevice(), SystemVolume.canSetVolume(device) else { return false }
            var volume = SystemVolume.volume(device)
            var muted = SystemVolume.isMuted(device)

            switch key {
            case .mute where SystemVolume.hasMute(device):
                muted.toggle()
                SystemVolume.setMuted(device, muted)
            case .mute:
                // Sortie sans sourdine matérielle : on simule avec le volume.
                if volume > 0 { volumeBeforeMute = volume; volume = 0 } else { volume = volumeBeforeMute ?? 0.5 }
                SystemVolume.setVolume(device, volume)
            default:
                volume = stepped(volume, key == .volumeUp ? step : -step)
                SystemVolume.setVolume(device, volume)
                if key == .volumeUp && muted {
                    muted = false
                    SystemVolume.setMuted(device, false)
                }
            }
            model.show(HUD(kind: .volume, value: volume, muted: muted))
        }
        return true
    }
}

// MARK: - Volume (CoreAudio)

enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address, value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) {
        var address = address, value = value
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    private static let muteAddress = address(kAudioDevicePropertyMute)

    static func outputDevice() -> AudioDeviceID? {
        get(AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal), AudioDeviceID(0))
    }

    static func canSetVolume(_ device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func hasMute(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress
        return AudioObjectHasProperty(device, &address)
    }

    static func volume(_ device: AudioDeviceID) -> Double {
        Double(get(device, volumeAddress, Float32(0)) ?? 0)
    }

    static func setVolume(_ device: AudioDeviceID, _ value: Double) {
        set(device, volumeAddress, Float32(value))
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        (get(device, muteAddress, UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        set(device, muteAddress, UInt32(muted ? 1 : 0))
    }
}

// MARK: - Luminosité (DisplayServices, framework privé)

final class Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getter: GetFn?
    private let setter: SetFn?
    private var target: Double?
    private var animated: Double = 0
    private var timer: Timer?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
    }

    private var builtInDisplay: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Valeur visée si une transition est en cours, sinon valeur réelle.
    var value: Double? {
        if let target { return target }
        guard let getter, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? Double(value) : nil
    }

    /// Transition douce vers la nouvelle valeur, comme macOS.
    func animate(to value: Double) {
        if target == nil { animated = self.value ?? value }
        target = value
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let target, let setter, let display = builtInDisplay else { return finish() }
        animated += (target - animated) * 0.3
        if abs(target - animated) < 0.003 { animated = target }
        _ = setter(display, Float(animated))
        if animated == target { finish() }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}
