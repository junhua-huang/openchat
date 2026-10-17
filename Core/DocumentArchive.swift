import Foundation
import zlib

// Small, bounded ZIP reader/writer for OOXML. It never extracts server paths to
// disk. Supports stored/deflated entries, validates CRC, rejects encrypted/ZIP64.
struct DocumentArchive {
    struct Entry { let name: String; let size: Int; let compressed: Int; let method: Int; let crc: UInt32; let offset: Int }
    let data: Data
    let entries: [Entry]
    init(_ data: Data) throws {
        guard data.count >= 22, data.count <= 12_000_000 else { throw AppFailure.message("ZIP 文件大小无效。") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try Self.read(data, i, 4) == 0x06054b50, i + 22 + (try Self.read(data, i + 20, 2)) == data.count { end = i; break }
        }
        guard let e = end, try Self.read(data, e + 4, 2) == 0, try Self.read(data, e + 6, 2) == 0 else {
            throw AppFailure.message("暂不支持分卷、加密或损坏的 ZIP。")
        }
        let count = try Self.read(data, e + 10, 2); var offset = try Self.read(data, e + 16, 4)
        guard count <= 2048, count == (try Self.read(data, e + 8, 2)), offset < e else { throw AppFailure.message("ZIP 目录过大或无效。") }
        var items: [Entry] = []; var total = 0; var names = Set<String>()
        for _ in 0..<count {
            guard try Self.read(data, offset, 4) == 0x02014b50 else { throw AppFailure.message("ZIP 目录损坏。") }
            let flags = try Self.read(data, offset + 8, 2); let method = try Self.read(data, offset + 10, 2)
            let compressed = try Self.read(data, offset + 20, 4); let size = try Self.read(data, offset + 24, 4)
            let length = try Self.read(data, offset + 28, 2)
            guard flags & 1 == 0, [0, 8].contains(method), offset + 46 + length <= e,
                  let name = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + length)), encoding: .utf8),
                  names.insert(name).inserted, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw AppFailure.message("ZIP 含不支持的条目或不安全路径。")
            }
            total += size
            guard total <= 64_000_000 else { throw AppFailure.message("ZIP 解压后内容过大。") }
            items.append(Entry(name: name, size: size, compressed: compressed, method: method,
                crc: UInt32(try Self.read(data, offset + 16, 4)), offset: try Self.read(data, offset + 42, 4)))
            offset += 46 + length + (try Self.read(data, offset + 30, 2)) + (try Self.read(data, offset + 32, 2))
        }
        self.data = data; entries = items
    }
    private static func read(_ data: Data, _ offset: Int, _ length: Int) throws -> Int {
        guard offset >= 0, length <= 4, offset + length <= data.count else { throw AppFailure.message("ZIP 条目越界。") }
        var result = 0
        for i in 0..<length { result |= Int(data[offset + i]) << (8 * i) }
        return result
    }
    func content(_ name: String, limit: Int = 4_000_000) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }), entry.size <= limit,
              try Self.read(data, entry.offset, 4) == 0x04034b50 else { throw AppFailure.message("文件内容不存在或过大。") }
        let start = entry.offset + 30 + (try Self.read(data, entry.offset + 26, 2)) + (try Self.read(data, entry.offset + 28, 2))
        guard start + entry.compressed <= data.count else { throw AppFailure.message("ZIP 数据被截断。") }
        let source = data.subdata(in: start..<(start + entry.compressed)); let result: Data
        if entry.method == 0 { result = source }
        else {
            var output = Data(count: max(entry.size, 1)); var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw AppFailure.message("无法初始化 ZIP 解码。")
            }
            defer { inflateEnd(&stream) }
            let status = source.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count); stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return inflate(&stream, Z_FINISH)
            } }
            guard status == Z_STREAM_END, Int(stream.total_out) == entry.size else { throw AppFailure.message("ZIP 解压失败或大小不符。") }
            result = output.prefix(entry.size)
        }
        guard result.count == entry.size, Self.checksum(result) == entry.crc else { throw AppFailure.message("ZIP 内容校验失败。") }
        return result
    }
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    static func make(_ files: [(String, Data)]) throws -> Data {
        guard !files.isEmpty, files.count <= 128, files.reduce(0, { $0 + $1.1.count }) <= 10_000_000 else {
            throw AppFailure.message("生成的 ZIP 内容过多。")
        }
        var data = Data(); var directory = Data(); var seen = Set<String>()
        func values(_ fields: [(Int, Int)]) -> Data {
            var out = Data()
            for (value, length) in fields { for i in 0..<length { out.append(UInt8((value >> (8 * i)) & 255)) } }
            return out
        }
        for (name, content) in files {
            let n = Data(name.utf8); let crc = Int(checksum(content)); let offset = data.count
            guard n.count <= 512, seen.insert(name).inserted, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw AppFailure.message("ZIP 文件名无效。")
            }
            data += values([(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(33,2),(crc,4),(content.count,4),(content.count,4),(n.count,2),(0,2)])
            data += n; data += content
            directory += values([(0x02014b50,4),(20,2),(20,2),(0x800,2),(0,2),(0,2),(33,2),(crc,4),(content.count,4),(content.count,4),(n.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)])
            directory += n
        }
        let offset = data.count; data += directory
        data += values([(0x06054b50,4),(0,2),(0,2),(files.count,2),(files.count,2),(directory.count,4),(offset,4),(0,2)])
        return data
    }
}
