import Foundation

/// Extracts the main icon from a Windows .exe and returns it as .ico file data,
/// which NSImage can read directly.
enum PEIcon {
    private static let rtIcon = 3
    private static let rtGroupIcon = 14

    static func icoData(fromExecutableAt url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return icoData(from: data)
    }

    static func icoData(from data: Data) -> Data? {
        let b = Bytes(data: data)

        // Find the resource directory by following the DOS header to the PE header and its optional header.
        guard b.u16(0) == 0x5A4D, let pe = b.u32(0x3C), b.u32(pe) == 0x4550,
              let sectionCount = b.u16(pe + 6), let optionalSize = b.u16(pe + 20) else { return nil }
        let optional = pe + 24
        let directories: Int
        switch b.u16(optional) {
        case 0x10B: directories = optional + 96   // PE32
        case 0x20B: directories = optional + 112  // PE32+
        default: return nil
        }
        guard let directoryCount = b.u32(directories - 4), directoryCount > 2,
              let resourceRVA = b.u32(directories + 16), resourceRVA != 0 else { return nil }

        struct Section { let va, size, raw: Int }
        var sections: [Section] = []
        for i in 0..<sectionCount {
            let s = optional + optionalSize + i * 40
            guard let vsize = b.u32(s + 8), let va = b.u32(s + 12),
                  let rawSize = b.u32(s + 16), let raw = b.u32(s + 20) else { return nil }
            sections.append(Section(va: va, size: max(vsize, rawSize), raw: raw))
        }
        func fileOffset(_ rva: Int) -> Int? {
            sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw }
        }
        guard let root = fileOffset(resourceRVA) else { return nil }

        struct Entry { let id: Int?; let target: Int; let isDirectory: Bool }
        func entries(_ dir: Int) -> [Entry] {
            guard let named = b.u16(dir + 12), let ids = b.u16(dir + 14) else { return [] }
            return (0..<min(named + ids, 4096)).compactMap { i in
                let e = dir + 16 + i * 8
                guard let name = b.u32(e), let target = b.u32(e + 4) else { return nil }
                return Entry(id: name & 0x8000_0000 == 0 ? name : nil,
                             target: root + (target & 0x7FFF_FFFF),
                             isDirectory: target & 0x8000_0000 != 0)
            }
        }
        // Follows the first entry at each level (the name, then the language) down to the bytes.
        func leaf(_ entry: Entry, depth: Int = 0) -> Data? {
            if entry.isDirectory {
                guard depth < 3, let first = entries(entry.target).first else { return nil }
                return leaf(first, depth: depth + 1)
            }
            guard let rva = b.u32(entry.target), let size = b.u32(entry.target + 4),
                  let offset = fileOffset(rva) else { return nil }
            return b.slice(offset, size)
        }

        let types = entries(root)
        guard let groups = types.first(where: { $0.id == rtGroupIcon && $0.isDirectory }),
              let iconType = types.first(where: { $0.id == rtIcon && $0.isDirectory }),
              let firstGroup = entries(groups.target).first,
              let group = leaf(firstGroup) else { return nil }

        var images: [Int: Data] = [:]
        for entry in entries(iconType.target) {
            if let id = entry.id, let image = leaf(entry) { images[id] = image }
        }

        // GRPICONDIR entries are 14 bytes: 8 bytes of size/colour info, 4 bytes of
        // length, then a 2-byte resource ID pointing at an RT_ICON image.
        let g = Bytes(data: group)
        guard let count = g.u16(4) else { return nil }
        var parts: [(info: Data, image: Data)] = []
        for i in 0..<count {
            let e = 6 + i * 14
            guard let info = g.slice(e, 8), let id = g.u16(e + 12), let image = images[id] else { continue }
            parts.append((info, image))
        }
        guard !parts.isEmpty else { return nil }

        // Put it back together as an .ico file: a header, then 16-byte directory entries, then the images.
        var ico = Data([0, 0, 1, 0])
        ico.appendLE16(parts.count)
        var offset = 6 + parts.count * 16
        for part in parts {
            ico.append(part.info)
            ico.appendLE32(part.image.count)
            ico.appendLE32(offset)
            offset += part.image.count
        }
        for part in parts { ico.append(part.image) }
        return ico
    }
}

/// Little-endian reads that check their bounds, so a malformed file just gives nil.
private struct Bytes {
    let data: Data

    func u8(_ o: Int) -> Int? {
        guard o >= 0, o < data.count else { return nil }
        return Int(data[data.startIndex + o])
    }
    func u16(_ o: Int) -> Int? {
        guard let lo = u8(o), let hi = u8(o + 1) else { return nil }
        return lo | hi << 8
    }
    func u32(_ o: Int) -> Int? {
        guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
        return lo | hi << 16
    }
    func slice(_ o: Int, _ n: Int) -> Data? {
        guard o >= 0, n >= 0, o + n <= data.count else { return nil }
        return data.subdata(in: data.startIndex + o ..< data.startIndex + o + n)
    }
}

private extension Data {
    mutating func appendLE16(_ v: Int) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    mutating func appendLE32(_ v: Int) { appendLE16(v & 0xFFFF); appendLE16(v >> 16 & 0xFFFF) }
}
