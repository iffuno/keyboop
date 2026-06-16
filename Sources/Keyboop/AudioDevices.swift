import CoreAudio
import Foundation

/// Перечисление микрофонов (устройств ввода) через CoreAudio — для меню «Микрофон»
/// и выбора устройства записи. Только чтение системы; выбор хранится как UID в настройках.
enum AudioDevices {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    /// Все устройства, у которых есть входные каналы (микрофоны).
    static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id) else { return nil }
            let name = stringProp(id, kAudioObjectPropertyName) ?? "Микрофон"
            let uid = stringProp(id, kAudioDevicePropertyDeviceUID) ?? ""
            return uid.isEmpty ? nil : Device(id: id, uid: uid, name: name)
        }
    }

    /// AudioDeviceID по сохранённому UID (или nil, если устройство пропало).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        for buf in abl where buf.mNumberChannels > 0 { return true }
        return false
    }

    private static func stringProp(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var str: CFString?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &str)
        guard status == noErr else { return nil }
        return str as String?
    }
}
