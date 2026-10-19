import Foundation

/// Writes 16 kHz mono 16-bit PCM WAV, patching the sizes in the header on `close()`.
public final class WAVWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0))
    }

    public func append(_ samples: [Int16]) throws {
        let data = samples.withUnsafeBytes { Data($0) }
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    public func close() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.close()
    }

    public static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(Wire.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)  // PCM
        u16(1)  // mono
        u32(rate)
        u32(rate * 2)  // byte rate
        u16(2)  // block align
        u16(16)  // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }
}
