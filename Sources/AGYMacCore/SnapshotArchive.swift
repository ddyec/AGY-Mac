import Foundation
import CArchive

/// Accept only bounded, seekable ZIPs produced by the gateway. Validate every
/// local header against the central directory before a native extractor writes.
public enum SnapshotArchive {
    private struct Entry { let name: String; let directory: Bool; let method: Int; let payload: Range<Int>; let size: Int; let crc: UInt32 }
    public static func validate(_ data: Data) throws { _ = try entries(data) }
    public static func extract(_ data: Data, to destination: URL) throws {
        let plan = try entries(data)
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw MacError.message("项目同步只写入新的目录，不覆盖本机文件。") }
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            for entry in plan {
                let target = destination.appendingPathComponent(entry.name)
                if entry.directory { try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); continue }
                let source = data.subdata(in:entry.payload)
                var output: Data
                if entry.method == 0 {
                    guard source.count == entry.size else { throw MacError.message("快照文件大小不符。") }
                    let crc = source.withUnsafeBytes { agy_crc32($0.bindMemory(to:UInt8.self).baseAddress,source.count) }
                    guard crc == entry.crc else { throw MacError.message("快照校验失败。") }; output = source
                } else {
                    output = Data(count:max(1,entry.size))
                    let valid = source.withUnsafeBytes { input in output.withUnsafeMutableBytes { result in agy_inflate_raw(input.bindMemory(to:UInt8.self).baseAddress,source.count,result.bindMemory(to:UInt8.self).baseAddress,entry.size,entry.crc) } }
                    guard valid == 1 else { throw MacError.message("快照压缩数据损坏或超过展开大小，未写入该文件。") }
                    output.count = entry.size
                }
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try output.write(to:target,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            }
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
    private static func entries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22, data.count <= Int(FileRules.maxFile) else { throw MacError.message("项目快照大小无效。") }
        func uint(_ offset: Int, _ bytes: Int) throws -> UInt64 {
            guard offset >= 0, offset <= data.count - bytes else { throw MacError.message("ZIP 结构不完整。") }
            return (0..<bytes).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func number(_ offset: Int, _ bytes: Int) throws -> Int { Int(try uint(offset,bytes)) }
        var end: Int?
        for offset in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) {
            if try uint(offset,4) == 0x06054b50, offset + 22 + (try number(offset+20,2)) == data.count { end = offset; break }
        }
        guard let end, try uint(end+4,2) == 0, try uint(end+6,2) == 0 else { throw MacError.message("不支持分卷或损坏的快照。") }
        let count = try number(end+10,2), size = try number(end+12,4), start = try number(end+16,4)
        guard count > 0, count <= 5000, try number(end+8,2) == count, start + size == end else { throw MacError.message("快照目录或数量无效。") }
        var output: [Entry] = []
        var central = start, total = 0, names = Set<String>(), files = Set<String>(), allPaths: [String] = [], intervals: [(Int,Int)] = []
        for _ in 0..<count {
            guard try uint(central,4) == 0x02014b50 else { throw MacError.message("ZIP 目录损坏。") }
            let flags = try number(central+8,2), method = try number(central+10,2), compressed = try number(central+20,4), expanded = try number(central+24,4)
            let nameLength = try number(central+28,2), extra = try number(central+30,2), comment = try number(central+32,2), local = try number(central+42,4)
            guard try uint(central+34,2) == 0, flags & ~0x0800 == 0, [0,8].contains(method), nameLength > 0, central + 46 + nameLength + extra + comment <= end,
                  let name = String(data:data.subdata(in:(central+46)..<(central+46+nameLength)),encoding:.utf8), !name.contains("\0") else { throw MacError.message("快照含不支持的压缩、加密或文件名。") }
            let parts = name.split(separator:"/",omittingEmptySubsequences:false), directory = name.hasSuffix("/")
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !parts.contains(".."), !parts.contains("."), !parts.dropLast(directory ? 1:0).contains("") else { throw MacError.message("快照含越界文件路径。") }
            let kind = Int((try uint(central+38,4)) >> 16) & 0xF000
            guard [0,0x8000,0x4000].contains(kind), kind != 0x4000 || directory else { throw MacError.message("快照不允许符号链接或特殊文件。") }
            let canonical = name.trimmingCharacters(in:CharacterSet(charactersIn:"/")).precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
            guard names.insert(canonical).inserted else { throw MacError.message("快照含在 Mac 上冲突的文件名。") }
            allPaths.append(canonical); if !directory { files.insert(canonical) }
            total += expanded; guard total <= FileRules.maxFile else { throw MacError.message("展开后的项目超过 25 MB。") }
            guard try uint(local,4) == 0x04034b50, try number(local+6,2) == flags, try number(local+8,2) == method,
                  try uint(local+14,4) == uint(central+16,4), try number(local+18,4) == compressed, try number(local+22,4) == expanded,
                  try number(local+26,2) == nameLength else { throw MacError.message("ZIP 文件头与目录不一致。") }
            let localExtra = try number(local+28,2), payload = local + 30 + nameLength + localExtra
            guard local < start, payload <= start, payload + compressed <= start,
                  data.subdata(in:(local+30)..<(local+30+nameLength)) == data.subdata(in:(central+46)..<(central+46+nameLength)) else { throw MacError.message("ZIP 文件边界无效。") }
            output.append(Entry(name:name,directory:directory,method:method,payload:payload..<(payload+compressed),size:expanded,crc:UInt32(try uint(central+16,4))))
            intervals.append((local,payload+compressed)); central += 46 + nameLength + extra + comment
        }
        guard central == end else { throw MacError.message("ZIP 目录长度不一致。") }
        var expected = 0
        for interval in intervals.sorted(by:{ $0.0 < $1.0 }) { guard interval.0 == expected else { throw MacError.message("ZIP 存在隐藏或重叠条目。") }; expected = interval.1 }
        guard expected == start else { throw MacError.message("ZIP 存在未登记文件。") }
        for path in allPaths {
            var parts = path.split(separator:"/"); _ = parts.popLast()
            while !parts.isEmpty { guard !files.contains(parts.joined(separator:"/")) else { throw MacError.message("快照目录与文件冲突。") }; _ = parts.popLast() }
        }
        return output
    }
}
