import CoreAudio
import Foundation

/// Перечисление микрофонов (устройств ввода) через CoreAudio — для меню «Микрофон»
/// и выбора устройства записи. Только чтение системы; выбор хранится как UID в настройках.
enum AudioDevices {
    struct Device { let id: AudioDeviceID; let uid: String; let name: String }

    /// UID устройства, которое СИСТЕМА считает текущим входом (Настройки → Звук → Вход).
    ///
    /// ⚠️ Зачем отдельная функция, если есть `AVCaptureDevice.default(for: .audio)` (репорт #23):
    /// это РАЗНЫЕ вещи. `AVCaptureDevice.default` отдаёт дефолт по мнению AVFoundation — как
    /// правило встроенный микрофон, — и он НЕ следует за выбором человека в системных настройках.
    /// Отсюда жалоба: «работаю с закрытым маком на внешнем экране, надеваю AirPods, а приложение
    /// на них не переключается»; человек кончил тем, что намертво прибил iPhone как микрофон.
    /// Правду знает только CoreAudio, и спрашивать надо именно его.
    ///
    /// Возвращаем UID, а не AudioDeviceID: сессию записи мы собираем через
    /// `AVCaptureDevice(uniqueID:)`, а UID — единственный идентификатор, общий для обоих миров
    /// (проверено побайтово на built-in / USB / Continuity / Bluetooth).
    static func systemDefaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidRef: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
              let uid = uidRef as String? , !uid.isEmpty else { return nil }
        return uid
    }

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
            let name = stringProp(id, kAudioObjectPropertyName) ?? L10n.t("audio.micFallback")
            let uid = stringProp(id, kAudioDevicePropertyDeviceUID) ?? ""
            return uid.isEmpty ? nil : Device(id: id, uid: uid, name: name)
        }
    }

    /// AudioDeviceID по сохранённому UID (или nil, если устройство пропало).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }?.id
    }

    /// Имя ТЕКУЩЕГО системного входа по умолчанию (диагностика «микрофон молчит»: видно,
    /// с какого устройства реально идёт запись — встроенный / EarPods / гарнитура).
    static func defaultInputName() -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return "?" }
        return stringProp(id, kAudioObjectPropertyName) ?? "?"
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

    /// Номинальная частота устройства — ИСТИНА о железе (в отличие от формата узла AVAudioEngine,
    /// который после смены CurrentDevice оставался протухшим навсегда — корень бага RODE+AirPods).
    /// Только для ДИАГНОСТИКИ в логе; на горячем пути старта не вызывать (читать в фоне).
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var sr = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr) == noErr, sr > 0 else { return nil }
        return sr
    }

    /// Слушатель смены СИСТЕМНОГО входа по умолчанию. Нужен в режиме «микрофон не закреплён»:
    /// AVCaptureSession прибита к конкретному устройству и за системным дефолтом сама не следует
    /// (в отличие от агрегата AVAudioEngine). Блок приходит на main.
    /// Возвращает токен — его же передать в removeDefaultInputListener.
    static func addDefaultInputListener(_ onChange: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let st = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        return st == noErr ? block : nil
    }

    static func removeDefaultInputListener(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
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
