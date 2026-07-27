import Foundation

let output = CommandLine.arguments.dropFirst().first
    ?? "Sources/NotchAgents/Resources/Sounds/CompletionChime.wav"
let sampleRate = 48_000
let duration = 0.68
let frameCount = Int(Double(sampleRate) * duration)

struct BellTone {
    var delay: Double
    var frequency: Double
    var amplitude: Double
    var decay: Double
}

let tones = [
    BellTone(delay: 0.000, frequency: 659.255, amplitude: 0.42, decay: 0.24),
    BellTone(delay: 0.082, frequency: 987.767, amplitude: 0.38, decay: 0.34),
    BellTone(delay: 0.090, frequency: 1_975.533, amplitude: 0.07, decay: 0.16),
]

func envelope(time: Double, tone: BellTone) -> Double {
    let local = time - tone.delay
    guard local >= 0 else { return 0 }
    let attack = min(1, local / 0.012)
    let release = min(1, max(0, (duration - time) / 0.08))
    return attack * attack * exp(-local / tone.decay) * release
}

var samples = [Int16]()
samples.reserveCapacity(frameCount)
for frame in 0..<frameCount {
    let time = Double(frame) / Double(sampleRate)
    var value = 0.0
    for tone in tones {
        let local = time - tone.delay
        guard local >= 0 else { continue }
        let phase = 2 * Double.pi * tone.frequency * local
        let timbre = sin(phase)
            + 0.16 * sin(phase * 2.006)
            + 0.045 * sin(phase * 3.011)
        value += tone.amplitude * envelope(time: time, tone: tone) * timbre
    }
    let softened = tanh(value * 1.08) * 0.58
    samples.append(Int16(max(-1, min(1, softened)) * Double(Int16.max)))
}

func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

let channelCount: UInt16 = 1
let bitsPerSample: UInt16 = 16
let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
let blockAlign = channelCount * (bitsPerSample / 8)
let audioByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
let riffSize = UInt32(36) + audioByteCount

var wave = Data()
wave.append(contentsOf: Array("RIFF".utf8))
wave.append(contentsOf: littleEndianBytes(riffSize))
wave.append(contentsOf: Array("WAVE".utf8))
wave.append(contentsOf: Array("fmt ".utf8))
wave.append(contentsOf: littleEndianBytes(UInt32(16)))
wave.append(contentsOf: littleEndianBytes(UInt16(1)))
wave.append(contentsOf: littleEndianBytes(channelCount))
wave.append(contentsOf: littleEndianBytes(UInt32(sampleRate)))
wave.append(contentsOf: littleEndianBytes(byteRate))
wave.append(contentsOf: littleEndianBytes(blockAlign))
wave.append(contentsOf: littleEndianBytes(bitsPerSample))
wave.append(contentsOf: Array("data".utf8))
wave.append(contentsOf: littleEndianBytes(audioByteCount))
for sample in samples {
    wave.append(contentsOf: littleEndianBytes(sample))
}

let outputURL = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try wave.write(to: outputURL, options: .atomic)
print(outputURL.path)
