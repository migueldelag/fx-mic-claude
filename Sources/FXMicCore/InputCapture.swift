import AVFoundation
import CoreAudio
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case noAudioUnit
    case setDevice(OSStatus)
    case start(Error)

    public var description: String {
        switch self {
        case .noAudioUnit: return "input node has no audio unit"
        case .setDevice(let s): return "could not select the device (OSStatus \(s))"
        case .start(let e): return "engine start failed: \(e)"
        }
    }
}

/// Pulls mono float audio from one specific input device (not the system default)
/// and delivers fixed-size hops on a private serial queue.
public final class InputCapture {
    public let device: AudioInputDevice
    public private(set) var sampleRate: Double = 0
    public private(set) var hop: Int = 480

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "fxmic.capture")
    private var pending: [Float] = []
    private let onHop: ([Float]) -> Void

    public init(device: AudioInputDevice, hopSeconds: Double = 0.010, onHop: @escaping ([Float]) -> Void) throws {
        self.device = device
        self.onHop = onHop
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.noAudioUnit }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.setDevice(status) }
        AudioDevices.setBufferFrameSize(device.id, frames: 480)
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        hop = max(1, Int((format.sampleRate * hopSeconds).rounded()))
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hop), format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
    }

    public func start() throws {
        do { try engine.start() } catch { throw CaptureError.start(error) }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Runs `block` on the processing queue, after any hops already queued.
    public func sync(_ block: () -> Void) {
        queue.sync(execute: block)
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: data[0], count: frames)
            }
        } else {
            let scale = 1 / Float(channels)
            for c in 0..<channels {
                let src = data[c]
                for i in 0..<frames { mono[i] += src[i] * scale }
            }
        }
        queue.async { [self] in
            pending.append(contentsOf: mono)
            while pending.count >= hop {
                let chunk = Array(pending[0..<hop])
                pending.removeFirst(hop)
                onHop(chunk)
            }
        }
    }
}
