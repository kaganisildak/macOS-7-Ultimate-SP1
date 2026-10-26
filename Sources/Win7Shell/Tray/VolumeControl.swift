import AudioToolbox
import CoreAudio
import Foundation
import Win7Core

/// The default output device's volume and mute state, through CoreAudio. Listener blocks run on the
/// main queue and follow default-device changes. Writes only happen on user input (slider, scroll,
/// mute button).
@MainActor
final class VolumeControl {
    private(set) var volume: Float = 0
    private(set) var muted = false
    private(set) var canSetVolume = false
    private(set) var canMute = false
    private(set) var hasDevice = false
    var onChange: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachDefaultDevice() }
        }
        deviceListener = block
        var addr = VolumeControl.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        attachDefaultDevice()
    }

    var level: VolumeLevel { TrayLogic.volumeLevel(volume: volume, muted: muted) }

    var tooltip: String {
        guard hasDevice else { return "No audio output device is installed" }
        return "Speakers: \(Int((volume * 100).rounded()))%" + (muted ? " (muted)" : "")
    }

    private func attachDefaultDevice() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = VolumeControl.defaultDeviceAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        let newDevice = status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
        if newDevice != device {
            detachDevice()
            device = newDevice
            attachDevice()
        }
        read()
    }

    private func attachDevice() {
        guard device != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        volumeListener = block
        var v = VolumeControl.volumeAddress, m = VolumeControl.muteAddress
        if AudioObjectHasProperty(device, &v) { AudioObjectAddPropertyListenerBlock(device, &v, .main, block) }
        if AudioObjectHasProperty(device, &m) { AudioObjectAddPropertyListenerBlock(device, &m, .main, block) }
    }

    private func detachDevice() {
        guard device != kAudioObjectUnknown, let block = volumeListener else { return }
        var v = VolumeControl.volumeAddress, m = VolumeControl.muteAddress
        AudioObjectRemovePropertyListenerBlock(device, &v, .main, block)
        AudioObjectRemovePropertyListenerBlock(device, &m, .main, block)
        volumeListener = nil
    }

    private func read() {
        hasDevice = device != kAudioObjectUnknown
        var v = VolumeControl.volumeAddress, m = VolumeControl.muteAddress
        var vol: Float32 = 0, mute: UInt32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let hasVolume = hasDevice && AudioObjectHasProperty(device, &v)
            && AudioObjectGetPropertyData(device, &v, 0, nil, &size, &vol) == noErr
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = hasDevice && AudioObjectHasProperty(device, &m)
            && AudioObjectGetPropertyData(device, &m, 0, nil, &size, &mute) == noErr
        var settable: DarwinBoolean = false
        canSetVolume = hasVolume && AudioObjectIsPropertySettable(device, &v, &settable) == noErr && settable.boolValue
        settable = false
        canMute = hasMute && AudioObjectIsPropertySettable(device, &m, &settable) == noErr && settable.boolValue
        volume = hasVolume ? max(0, min(1, vol)) : 0
        muted = hasMute && mute != 0
        onChange?()
    }

    /// Sets the output volume (0…1). Only ever called from user input.
    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        var v = VolumeControl.volumeAddress
        var vol = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(device, &v, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
    }

    /// Steps the volume by `notches` × 0.05 (scroll wheel over the icon).
    func step(notches: Int) {
        setVolume(volume + Float(notches) * 0.05)
    }

    /// Toggles mute. Only ever called from the flyout's mute button.
    func toggleMute() {
        guard canMute else { return }
        var m = VolumeControl.muteAddress
        var value: UInt32 = muted ? 0 : 1
        AudioObjectSetPropertyData(device, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
