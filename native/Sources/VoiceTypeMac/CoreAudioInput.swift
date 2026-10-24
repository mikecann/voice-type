import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import VoiceTypeCore

// The microphone through Core Audio's AUHAL output unit, in place of PortAudio.
//
// The unit is opened (initialised) while idle and only started on key-down, so the orange dot
// only shows while someone talks. Its input callback runs on Core Audio's real-time thread,
// so it only renders into a preallocated buffer and copies into a lock-free ring. Everything
// else (resampling to 16 kHz mono, handing blocks on) happens on a drain queue every 10 ms.
//
// The AUHAL can't change sample rate on input, so it's asked for mono float at the device's
// own rate, which takes the first channel as PortAudio did, and Resampler does the rest.

enum CoreAudioError: LocalizedError {
    case status(String, OSStatus)
    case noHALUnit

    var errorDescription: String? {
        switch self {
        case let .status(what, status): return "\(what) failed (\(status))"
        case .noHALUnit: return "no AUHAL audio unit"
        }
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.status(what, status) }
}

final class CoreAudioCatalog: AudioDeviceCatalog, @unchecked Sendable {
    func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in Self.inputChannels(id) > 0 ? InputDevice(id: id, name: Self.name(id)) : nil }
    }

    func defaultInputDevice() -> InputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return InputDevice(id: id, name: Self.name(id))
    }

    static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return "" }
        return PythonText.strip(value as String)
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// A single-producer, single-consumer ring of samples: the real-time callback writes, the
/// drain queue reads, and neither ever takes a lock.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(capacity: Int) {
        // A power of two, so positions wrap with a mask.
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    /// Real-time safe. If the drain has fallen a whole ring behind, the block is dropped
    /// and counted rather than overwriting audio not yet read.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        guard count <= capacity - (w - r) else {
            dropped.add(count, ordering: .relaxed)
            return
        }
        for i in 0..<count { storage[(w + i) & (capacity - 1)] = samples[i] }
        written.store(w + count, ordering: .releasing)
    }

    func readAll() -> [Float] {
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        guard w > r else { return [] }
        let out = (r..<w).map { storage[$0 & (capacity - 1)] }
        read.store(w, ordering: .releasing)
        return out
    }

    func takeDropped() -> Int { dropped.exchange(0, ordering: .relaxed) }
}

/// What the real-time callback can see. Kept apart from the stream so it's fully built before
/// Core Audio gets a pointer to it.
final class RenderContext: @unchecked Sendable {
    var unit: AudioUnit?
    let ring: SampleRing
    let maxFrames = 16_384
    let buffer: UnsafeMutablePointer<Float>
    let bufferList: UnsafeMutablePointer<AudioBufferList>
    let renderError = Atomic<Int32>(0)

    init(ring: SampleRing) {
        self.ring = ring
        buffer = .allocate(capacity: maxFrames)
        bufferList = .allocate(capacity: 1)
        bufferList.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: buffer)))
    }

    deinit {
        buffer.deallocate()
        bufferList.deallocate()
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, Int(frames) <= maxFrames else { return noErr }
        bufferList.pointee.mBuffers.mDataByteSize = frames * 4
        bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(buffer)
        let status = AudioUnitRender(unit, flags, time, 1, frames, bufferList)
        if status != noErr {
            renderError.store(status, ordering: .relaxed)
            return status
        }
        // A unit may hand back its own buffer instead of filling ours, so read from mData.
        guard let data = bufferList.pointee.mBuffers.mData else { return noErr }
        ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frames))
        return noErr
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, time, _, frames, _ in
    Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
}

/// Streams whose Core Audio calls hung, kept for the life of the process. Nothing may stop,
/// close or free them: freeing would close them (deinit), and the unit's callback still
/// points at their render context. The process restarts soon after anyway.
enum AudioQuarantine {
    private static let streams = Mutex<[CoreAudioInputStream]>([])

    static func keep(_ stream: CoreAudioInputStream) { streams.withLock { $0.append(stream) } }
    static var count: Int { streams.withLock { $0.count } }
}

final class CoreAudioInputStream: AudioInputStream, @unchecked Sendable {
    let device: InputDevice
    let deviceRate: Double
    private let context: RenderContext
    private let unit: AudioUnit
    private let resampler: Resampler
    private let drainQueue = DispatchQueue(label: "voice-type.audio-drain", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let onAudio: @Sendable ([Float]) -> Void
    private let onError: @Sendable (String) -> Void
    private var reportedError = false
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var closed = false
    private let abandoned = Atomic<Bool>(false)

    init(device: InputDevice, onAudio: @escaping @Sendable ([Float]) -> Void, onError: @escaping @Sendable (String) -> Void) throws {
        self.device = device
        self.onAudio = onAudio
        self.onError = onError

        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CoreAudioError.noHALUnit }
        var made: AudioUnit?
        try check(AudioComponentInstanceNew(component, &made), "AudioComponentInstanceNew")
        let unit = made!
        self.unit = unit
        var ok = false
        defer { if !ok { AudioComponentInstanceDispose(unit) } }

        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable output")
        var id = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read device format")
        let rate = hardware.mSampleRate > 0 ? hardware.mSampleRate : 48_000
        deviceRate = rate
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set client format")

        // Five seconds of headroom; the drain empties it every 10 ms.
        context = RenderContext(ring: SampleRing(capacity: Int(rate * 5)))
        context.unit = unit
        var callback = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")

        resampler = Resampler(inputRate: rate)
        ok = true
        watchDeviceAlive()
    }

    deinit { close() }

    func abandon() {
        // Only flags and a reference: the hung call may still hold the HAL's lock.
        guard !abandoned.exchange(true, ordering: .relaxed) else { return }
        AudioQuarantine.keep(self)
    }

    func start() throws {
        guard !abandoned.load(ordering: .relaxed) else { throw CoreAudioHang("Starting an abandoned stream") }
        drainQueue.sync {
            _ = context.ring.readAll()
            resampler.reset()
            reportedError = false
        }
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drain(final: false) }
        self.timer = timer
        timer.resume()
    }

    /// Stops the microphone, then hands on the last of the audio before returning, so the
    /// recording has everything up to key-up.
    func stop() throws {
        let status = AudioOutputUnitStop(unit)
        timer?.cancel()
        timer = nil
        drainQueue.sync { drain(final: true) }
        try check(status, "AudioOutputUnitStop")
    }

    func close() {
        guard !closed, !abandoned.load(ordering: .relaxed) else { return }
        closed = true
        timer?.cancel()
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        if let aliveListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device.id, &address, drainQueue, aliveListener)
        }
    }

    private func watchDeviceAlive() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let id = device.id
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            var alive: UInt32 = 1
            var size = UInt32(4)
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &alive) == noErr, alive == 0 {
                self?.onError("the device went away")
            }
        }
        if AudioObjectAddPropertyListenerBlock(id, &address, drainQueue, listener) == noErr { aliveListener = listener }
    }

    /// On the drain queue: resample whatever the callback wrote, and pass it on.
    private func drain(final: Bool) {
        let raw = context.ring.readAll()
        if let status = Optional(context.renderError.exchange(0, ordering: .relaxed)), status != 0, !reportedError {
            reportedError = true
            onError("AudioUnitRender returned \(status)")
        }
        let dropped = context.ring.takeDropped()
        if dropped > 0 { onError("dropped \(dropped) samples while the drain was behind") }
        let converted = convert(raw, endOfStream: final)
        if !converted.isEmpty { onAudio(converted) }
    }

    private func convert(_ raw: [Float], endOfStream: Bool) -> [Float] {
        endOfStream ? resampler.finish(raw) : resampler.process(raw)
    }
}

/// Device-rate mono float to 16 kHz mono float, streamed: blocks go in as they arrive and
/// finish() flushes the converter's tail at key-up, so the result is the same however the
/// audio was split into blocks. AVAudioConverter at maximum quality, the same Apple converter
/// and setting PortAudio's Core Audio backend uses by default.
final class Resampler: @unchecked Sendable {
    let inputRate: Double
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init(inputRate: Double) {
        self.inputRate = inputRate
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }

    func process(_ samples: [Float]) -> [Float] { convert(samples, endOfStream: false) }

    /// The last block, then everything the converter still holds. Ready for the next
    /// recording afterwards.
    func finish(_ samples: [Float] = []) -> [Float] {
        let out = convert(samples, endOfStream: true)
        converter.reset()
        return out
    }

    func reset() { converter.reset() }

    private func convert(_ raw: [Float], endOfStream: Bool) -> [Float] {
        guard !raw.isEmpty || endOfStream else { return [] }
        var pending: AVAudioPCMBuffer?
        if !raw.isEmpty, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(raw.count)) {
            input.frameLength = AVAudioFrameCount(raw.count)
            raw.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: raw.count) }
            pending = input
        }
        var out: [Float] = []
        let capacity = AVAudioFrameCount(Double(raw.count) * Double(sampleRate) / inputRate) + 1024
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let buffer = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if output.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            // A full output buffer means there may be more for this input.
            if status == .haveData && output.frameLength > 0 { continue }
            break
        }
        return out
    }
}

final class CoreAudioStreamFactory: AudioStreamFactory, @unchecked Sendable {
    func open(_ device: InputDevice, onAudio: @escaping @Sendable ([Float]) -> Void, onError: @escaping @Sendable (String) -> Void) throws -> AudioInputStream {
        try CoreAudioInputStream(device: device, onAudio: onAudio, onError: onError)
    }
}

/// Opens a device for a moment to prove it delivers real samples. From probe_input_device.
///
/// Every Core Audio step (open, start, stop, close) runs under the 2 s limit. A step that
/// hangs abandons the stream, so nothing touches that unit again, and the probe throws
/// CoreAudioHang, which makes the app restart rather than try another unit in a process whose
/// HAL lock may be held for good.
final class CoreAudioProbe: MicrophoneProbing, @unchecked Sendable {
    let catalog: AudioDeviceCatalog

    init(catalog: AudioDeviceCatalog) { self.catalog = catalog }

    /// The stream an open produced, handed over between the open's thread and the probe. If
    /// the probe gave up waiting first, a stream that turns up later is abandoned instead.
    private final class OpenSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<CoreAudioInputStream, Error>?
        private var gaveUp = false

        func opened(_ made: Result<CoreAudioInputStream, Error>) {
            let late = lock.withLock { () -> Bool in
                if !gaveUp { result = made }
                return gaveUp
            }
            if late, case let .success(stream) = made { stream.abandon() }
        }

        func giveUp() { lock.withLock { gaveUp = true } }

        func take() throws -> CoreAudioInputStream {
            guard let result = lock.withLock({ result }) else { throw CoreAudioError.noHALUnit }
            return try result.get()
        }
    }

    func probe(_ selection: MicrophoneSelection, seconds: Double) throws -> ProbeResult {
        let device = try DeviceResolver.resolve(selection, in: catalog)
        let collected = Mutex<[Float]>([])
        let slot = OpenSlot()
        let opened = BoundedRunner.run(timeout: Deadlines.audioStartStop, name: "voice-type-probe-open") {
            slot.opened(Result { try CoreAudioInputStream(device: device, onAudio: { block in collected.withLock { $0 += block } }, onError: { _ in }) })
        }
        guard opened else {
            slot.giveUp()
            throw CoreAudioHang("Opening '\(device.name)' for the microphone check")
        }
        let stream = try slot.take()

        func step(_ what: String, _ work: @escaping @Sendable () -> Void) throws {
            guard BoundedRunner.run(timeout: Deadlines.audioStartStop, name: "voice-type-probe", work) else {
                stream.abandon()
                throw CoreAudioHang("\(what) '\(device.name)' for the microphone check")
            }
        }
        let started = Mutex(false)
        try step("Starting") { started.withLock { $0 = (try? stream.start()) != nil } }
        guard started.withLock({ $0 }) else {
            try step("Closing") { stream.close() }
            return ProbeResult(ready: false, device: device, reason: "could not start")
        }
        Thread.sleep(forTimeInterval: seconds)
        try step("Stopping") { try? stream.stop() }
        try step("Closing") { stream.close() }
        let samples = collected.withLock { $0 }
        if let reason = ProbeResult.rejection(for: samples) { return ProbeResult(ready: false, device: device, reason: reason) }
        return ProbeResult(ready: true, device: device)
    }
}

/// Tells the app when inputs come and go or the default input changes. Core Audio fires
/// several of these for one plug-in, so they're gathered into one call half a second later.
final class AudioDeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice-type.device-watch")
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
