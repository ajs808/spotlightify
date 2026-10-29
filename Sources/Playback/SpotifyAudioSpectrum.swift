import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Live frequency levels of whatever the Spotify app on this Mac is playing, captured with a
/// Core Audio process tap. Runs only between `start()` and `stop()`.
@MainActor
final class AudioSpectrumMonitor {
    static let bandCount = 16

    private let analyzer = SpectrumAnalyzer(bandCount: AudioSpectrumMonitor.bandCount)
    private let session = TapSession()

    /// The current band levels from 0 to 1, or nil when there's no live audio to show.
    func levels() -> [Float]? {
        analyzer.levelsIfSignalPresent()
    }

    func start() {
        guard #available(macOS 14.2, *) else { return }
        session.start(analyzer: analyzer)
    }

    func stop() {
        session.stop()
    }
}

/// Owns the tap and does its setup off the main thread, since creating the aggregate device is slow.
private final class TapSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.spotlightify.audio-tap")
    private var tap: AnyObject?

    func start(analyzer: SpectrumAnalyzer) {
        queue.async {
            guard self.tap == nil, #available(macOS 14.2, *) else { return }
            do {
                self.tap = try SpotifyProcessTap(analyzer: analyzer)
            } catch {
                AppLogger.shared.log("audio tap unavailable error=\(error)", category: "visualizer")
            }
        }
    }

    func stop() {
        queue.async {
            if #available(macOS 14.2, *), let tap = self.tap as? SpotifyProcessTap {
                tap.invalidate()
            }
            self.tap = nil
        }
    }
}

private struct AudioTapError: Error, CustomStringConvertible {
    let description: String

    init(_ step: String, _ status: OSStatus = noErr) {
        description = status == noErr ? step : "\(step) status=\(status)"
    }
}

@available(macOS 14.2, *)
private final class SpotifyProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(analyzer: SpectrumAnalyzer) throws {
        // Spotify may play audio from a helper process, so tap every process it owns.
        let processes = try Self.processObjects().filter {
            Self.bundleID(of: $0)?.hasPrefix("com.spotify.client") == true
        }
        guard !processes.isEmpty else { throw AudioTapError("Spotify has no audio process") }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioTapError("create tap", status) }

        do {
            let format: AudioStreamBasicDescription = try Self.property(tapID, kAudioTapPropertyFormat)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw AudioTapError("unsupported tap format")
            }
            analyzer.reset(sampleRate: Float(format.mSampleRate))

            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Spotlightify Visualizer",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
            guard status == noErr else { throw AudioTapError("create aggregate device", status) }

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inputData, _, _, _ in
                analyzer.process(inputData)
            }
            guard status == noErr else { throw AudioTapError("create IO proc", status) }

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else { throw AudioTapError("start device", status) }
        } catch {
            invalidate()
            throw error
        }
    }

    func invalidate() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func property<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
        guard status == noErr else { throw AudioTapError("read property \(selector)", status) }
        return value.pointee
    }

    private static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func processObjects() throws -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr else { throw AudioTapError("list processes", status) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects)
        guard status == noErr else { throw AudioTapError("list processes", status) }
        return objects
    }

    private static func bundleID(of processObject: AudioObjectID) -> String? {
        stringProperty(processObject, kAudioProcessPropertyBundleID)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioDeviceID = try property(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultSystemOutputDevice
        )
        guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            throw AudioTapError("read output device UID")
        }
        return uid
    }
}

/// Turns tapped audio into smoothed, log-spaced band levels. `process` runs on Core Audio's
/// IO thread; `levelsIfSignalPresent` is read from the UI.
private final class SpectrumAnalyzer: @unchecked Sendable {
    private struct Output {
        var levels: [Float]
        var lastSignalTime: CFAbsoluteTime = 0
    }

    private static let fftSize = 2048
    private static let log2Size = vDSP_Length(11)
    /// How long silence lasts before the UI falls back, e.g. when paused or permission is denied.
    private static let silenceTimeout: CFAbsoluteTime = 1.0

    private let bandCount: Int
    private let fftSetup: FFTSetup
    private let window: [Float]
    // Only touched on the IO thread, so they need no lock.
    private var samples: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var smoothed: [Float]
    private var bandBins: [Range<Int>] = []
    private let output: OSAllocatedUnfairLock<Output>

    init(bandCount: Int) {
        self.bandCount = bandCount
        fftSetup = vDSP_create_fftsetup(Self.log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        samples = [Float](repeating: 0, count: Self.fftSize)
        windowed = [Float](repeating: 0, count: Self.fftSize)
        real = [Float](repeating: 0, count: Self.fftSize / 2)
        imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        power = [Float](repeating: 0, count: Self.fftSize / 2)
        smoothed = [Float](repeating: 0, count: bandCount)
        output = OSAllocatedUnfairLock(initialState: Output(levels: [Float](repeating: 0, count: bandCount)))
        reset(sampleRate: 48_000)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Called before the tap starts, so it never races `process`.
    func reset(sampleRate: Float) {
        // Log-spaced bands from 50 Hz to 14 kHz, so bass doesn't take every bar.
        let binWidth = sampleRate / Float(Self.fftSize)
        let lowest: Float = 50
        let highest = min(14_000, sampleRate / 2)
        let ratio = pow(highest / lowest, 1 / Float(bandCount))
        bandBins = (0..<bandCount).map { band in
            let start = max(1, Int(lowest * pow(ratio, Float(band)) / binWidth))
            let end = max(start + 1, Int(lowest * pow(ratio, Float(band + 1)) / binWidth))
            return start..<min(end, Self.fftSize / 2)
        }
        samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        smoothed.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    func levelsIfSignalPresent() -> [Float]? {
        output.withLock { output in
            CFAbsoluteTimeGetCurrent() - output.lastSignalTime < Self.silenceTimeout ? output.levels : nil
        }
    }

    func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, first.mNumberChannels > 0, first.mData != nil else { return }
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frameCount > 0 else { return }

        // Mix every channel down to mono and append it to the rolling window.
        let newCount = min(frameCount, Self.fftSize)
        var peak: Float = 0
        samples.withUnsafeMutableBufferPointer { samples in
            let base = samples.baseAddress!
            base.update(from: base + newCount, count: Self.fftSize - newCount)
            let tail = base + (Self.fftSize - newCount)
            tail.update(repeating: 0, count: newCount)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                for frame in 0..<newCount {
                    for channel in 0..<channels {
                        tail[frame] += data[(frameCount - newCount + frame) * channels + channel]
                    }
                }
            }
            peak = vDSP.maximumMagnitude(UnsafeBufferPointer(start: tail, count: newCount))
        }

        // A tap without permission delivers silence, which reads as "no live audio".
        let hasSignal = peak > 1e-4
        computeBands()

        output.withLock { output in
            output.levels = smoothed
            if hasSignal {
                output.lastSignalTime = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    private func computeBands() {
        vDSP.multiply(samples, window, result: &windowed)
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                windowed.withUnsafeBufferPointer { windowed in
                    windowed.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { power in
                    vDSP_zvmags(&split, 1, power.baseAddress!, 1, vDSP_Length(Self.fftSize / 2))
                }
            }
        }

        // Full scale is about (N/2)², so this puts a loud tone near 0 dB.
        let reference = Float(Self.fftSize * Self.fftSize) / 4
        for band in 0..<bandCount {
            let bins = bandBins[band]
            var total: Float = 0
            for bin in bins { total += power[bin] }
            let mean = total / Float(bins.count) / reference
            // Music has less energy up high; tilt so a pink spectrum reads level across the bars.
            let decibels = 10 * log10(mean + 1e-12) + Float(band) * 3.2
            // Typical mastered music sits mid-height, leaving headroom for beats.
            let target = min(max((decibels + 36) / 50, 0), 1)
            // Rise quickly and fall slowly, like a level meter.
            let previous = smoothed[band]
            smoothed[band] = target > previous ? previous + (target - previous) * 0.6 : previous * 0.86 + target * 0.14
        }
    }
}
