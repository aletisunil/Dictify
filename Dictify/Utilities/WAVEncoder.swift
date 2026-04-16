import Foundation

struct WAVEncoder {
    static func encode(pcmData: Data, sampleRate: Int = 16000, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        let dataSize = sampleCount * MemoryLayout<Int16>.size
        let fileSize = 36 + dataSize

        var wavData = Data(capacity: 44 + dataSize)
        wavData.append(contentsOf: "RIFF".utf8)
        var fileSizeLE = UInt32(fileSize).littleEndian
        wavData.append(Data(bytes: &fileSizeLE, count: 4))

        wavData.append(contentsOf: "WAVE".utf8)

        wavData.append(contentsOf: "fmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        wavData.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        wavData.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(channels).littleEndian
        wavData.append(Data(bytes: &numChannels, count: 2))
        var sampleRateLE = UInt32(sampleRate).littleEndian
        wavData.append(Data(bytes: &sampleRateLE, count: 4))
        var byteRate = UInt32(sampleRate * channels * bitsPerSample / 8).littleEndian
        wavData.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(channels * bitsPerSample / 8).littleEndian
        wavData.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSampleLE = UInt16(bitsPerSample).littleEndian
        wavData.append(Data(bytes: &bitsPerSampleLE, count: 2))

        wavData.append(contentsOf: "data".utf8)
        var dataSizeLE = UInt32(dataSize).littleEndian
        wavData.append(Data(bytes: &dataSizeLE, count: 4))

        var int16Data = Data(count: dataSize)
        int16Data.withUnsafeMutableBytes { output in
            let int16Samples = output.bindMemory(to: Int16.self)
            pcmData.withUnsafeBytes { input in
                let floatSamples = input.bindMemory(to: Float.self)
                for index in 0..<sampleCount {
                    let clamped = max(-1.0, min(1.0, floatSamples[index]))
                    int16Samples[index] = Int16(clamped * Float(Int16.max)).littleEndian
                }
            }
        }
        wavData.append(int16Data)

        return wavData
    }
}
