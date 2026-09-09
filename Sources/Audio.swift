import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

func audioProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) { pointer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return result
}

func inputDevices() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
              let name: CFString = audioProperty(id, kAudioObjectPropertyName, initial: "" as CFString),
              let uid: CFString = audioProperty(id, kAudioDevicePropertyDeviceUID, initial: "" as CFString) else { return nil }
        return InputDevice(id: id, uid: uid as String, name: name as String)
    }
}

func defaultInput() -> AudioDeviceID? {
    audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
}

struct DictationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var file: AVAudioFile?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "dictation.audio.capture")
    private let lock = NSLock()
    private var failure: String?
    private var frames: AVAudioFramePosition = 0
    private var energy: Double = 0
    private var peak: Double = 0
    private let rate = 16000.0
    private let limit: AVAudioFramePosition = 1_920_000
    private var deviceID: AudioDeviceID = 0
    private var active = false
    private var lastBuffer = Date()
    var onDeviceChange: (() -> Void)?
    var onLimit: (() -> Void)?
    var url: URL?

    var level: Double { lock.lock(); defer { lock.unlock() }; return peak }
    var isDeviceAlive: Bool {
        let alive: UInt32 = audioProperty(deviceID, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0
        return alive == 1
    }
    var hasCaptureFailure: Bool {
        lock.lock(); defer { lock.unlock() }
        return failure != nil || (active && Date().timeIntervalSince(lastBuffer) > 8)
    }

    func start(uid: String) throws -> String {
        let devices = inputDevices()
        guard let selected = uid.isEmpty ? devices.first(where: { $0.id == defaultInput() }) : devices.first(where: { $0.uid == uid }),
              let device = AVCaptureDevice(uniqueID: selected.uid) else {
            throw DictationError(L("找不到輸入裝置，請重新選擇麥克風。"))
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); throw DictationError(L("無法開啟所選麥克風。"))
        }
        session.addInput(input); session.addOutput(output); session.commitConfiguration()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrcaDictation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = folder.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        do {
            file = try AVAudioFile(forWriting: path, settings: format.settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        self.url = path; self.session = session; self.output = output; deviceID = selected.id
        frames = 0; energy = 0; failure = nil; peak = 0; active = true; lastBuffer = Date()
        output.setSampleBufferDelegate(self, queue: queue)
        // Watch the selected input, not AVAudioEngine's unrelated output-route changes.
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in self?.onDeviceChange?() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in self?.onDeviceChange?() })
        session.startRunning()
        guard session.isRunning else { _ = stop(); cleanup(); throw DictationError(L("收音未能啟動，請檢查麥克風權限。")) }
        return selected.name
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); defer { lock.unlock() }
        guard active, failure == nil, frames < limit else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate == rate, asbd.mChannelsPerFrame == 1, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            failure = L("收音格式無效。"); return
        }
        let count = min(CMSampleBufferGetNumSamples(sampleBuffer), Int(limit - frames))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr,
              let samples = buffer.floatChannelData?[0] else { failure = L("無法讀取收音資料。"); return }
        var power: Double = 0
        for i in 0..<count { power += Double(samples[i] * samples[i]) }
        energy += power; peak = sqrt(power / Double(count)); lastBuffer = Date()
        do { try file?.write(from: buffer) } catch { failure = error.localizedDescription }
        frames += AVAudioFramePosition(count)
        if frames >= limit { DispatchQueue.main.async { [weak self] in self?.onLimit?() } }
    }

    func stop() -> String? {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        session?.stopRunning(); output?.setSampleBufferDelegate(nil, queue: nil)
        queue.sync {} // Drain already-delivered buffers before closing the WAV.
        lock.lock()
        active = false; file = nil
        let error = failure ?? (frames < AVAudioFramePosition(rate) ? L("錄音不足一秒。") : nil)
            ?? (sqrt(energy / Double(max(frames, 1))) < 0.001 ? L("沒有收到清晰聲音，未貼上文字。") : nil)
        lock.unlock()
        session = nil; output = nil
        return error
    }
    func cleanup() {
        if session != nil { _ = stop() }
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        url = nil
    }
    deinit { cleanup() }
}
