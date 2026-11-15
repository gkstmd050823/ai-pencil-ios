import Foundation

/// Why a file could not be added to. The export then falls back on having PDFKit write a new file.
struct PDFAppendError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// One thing in a PDF file, as far as this code needs to tell them apart.
enum PDFValue {
    case null
    case bool(Bool)
    /// A number as it is written in the file.
    case number(String)
    case name(String)
    case string([UInt8])
    case array([PDFValue])
    case dict(PDFDict)
    /// Another object of the file, by its number and generation.
    case ref(Int, Int)

    var int: Int? {
        guard case .number(let text) = self else { return nil }
        if let whole = Int(text) { return whole }
        if let real = Double(text), real.isFinite, abs(real) < 1e15 { return Int(real) }
        return nil
    }

    var dict: PDFDict? {
        if case .dict(let value) = self { return value }
        return nil
    }

    var array: [PDFValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var refNumber: Int? {
        if case .ref(let number, _) = self { return number }
        return nil
    }

    var nameText: String? {
        if case .name(let text) = self { return text }
        return nil
    }
}

/// A dictionary that keeps its keys in the order they were put in, so that what is written back reads
/// like what was read.
struct PDFDict {
    private(set) var keys: [String] = []
    private var items: [String: PDFValue] = [:]

    subscript(key: String) -> PDFValue? {
        get { items[key] }
        set {
            if let newValue {
                if items[key] == nil { keys.append(key) }
                items[key] = newValue
            } else if items.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
}

/// Reads the things a PDF file is made of from its bytes.
struct PDFParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var pos: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, at pos: Int = 0) {
        self.bytes = bytes
        self.pos = min(max(pos, 0), bytes.count)
    }

    static func isWhite(_ c: UInt8) -> Bool {
        c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
    }

    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    static func hex(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c) - 0x30
        case 0x41...0x46: return Int(c) - 0x41 + 10
        case 0x61...0x66: return Int(c) - 0x61 + 10
        default: return nil
        }
    }

    /// A whole number, with or without a sign.
    static func whole(_ word: String) -> Int? {
        var digits = Substring(word)
        if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(word)
    }

    static func isNumber(_ word: String) -> Bool {
        var digits = 0
        for c in word {
            if c >= "0" && c <= "9" {
                digits += 1
            } else if c != "+" && c != "-" && c != "." {
                return false
            }
        }
        return digits > 0
    }

    /// Steps over blanks and comments.
    mutating func skip() {
        let n = bytes.count
        while pos < n {
            let c = bytes[pos]
            if PDFParser.isWhite(c) {
                pos += 1
            } else if c == 0x25 {
                // % starts a comment that runs to the end of the line.
                while pos < n, bytes[pos] != 10, bytes[pos] != 13 { pos += 1 }
            } else {
                break
            }
        }
    }

    /// The run of ordinary characters at the position: a number or a keyword.
    mutating func token() -> String {
        let n = bytes.count
        var scalars = String.UnicodeScalarView()
        while pos < n, !PDFParser.isWhite(bytes[pos]), !PDFParser.isDelimiter(bytes[pos]) {
            scalars.append(Unicode.Scalar(bytes[pos]))
            pos += 1
        }
        return String(scalars)
    }

    func starts(_ word: String) -> Bool {
        var i = pos
        for c in word.utf8 {
            guard i < bytes.count, bytes[i] == c else { return false }
            i += 1
        }
        return true
    }

    mutating func integer() throws -> Int {
        skip()
        guard let value = PDFParser.whole(token()) else { throw PDFAppendError("a whole number was expected") }
        return value
    }

    mutating func keyword(_ word: String) throws {
        skip()
        guard token() == word else { throw PDFAppendError("\(word) was expected") }
    }

    mutating func value(depth: Int = 0) throws -> PDFValue {
        guard depth <= 60 else { throw PDFAppendError("nested too deep") }
        skip()
        guard pos < bytes.count else { throw PDFAppendError("the file ends in the middle of something") }
        switch bytes[pos] {
        case 0x3C:
            if starts("<<") {
                pos += 2
                return try dictionary(depth: depth)
            }
            return try hexString()
        case 0x5B:
            pos += 1
            var items: [PDFValue] = []
            while true {
                skip()
                guard pos < bytes.count else { throw PDFAppendError("a list is not closed") }
                if bytes[pos] == 0x5D {
                    pos += 1
                    return .array(items)
                }
                items.append(try value(depth: depth + 1))
            }
        case 0x2F:
            pos += 1
            return .name(name())
        case 0x28:
            return try literalString()
        default:
            break
        }
        let word = token()
        guard !word.isEmpty else { throw PDFAppendError("an unexpected character") }
        if word == "true" { return .bool(true) }
        if word == "false" { return .bool(false) }
        if word == "null" { return .null }
        if let first = PDFParser.whole(word) {
            // Two whole numbers and an R are a reference to another object.
            let back = pos
            skip()
            let second = token()
            if !second.isEmpty, second.allSatisfy({ $0 >= "0" && $0 <= "9" }), let generation = Int(second) {
                skip()
                if pos < bytes.count, bytes[pos] == 0x52 {
                    let after = pos + 1
                    if after >= bytes.count || PDFParser.isWhite(bytes[after]) || PDFParser.isDelimiter(bytes[after]) {
                        pos = after
                        return .ref(first, generation)
                    }
                }
            }
            pos = back
            return .number(word)
        }
        guard PDFParser.isNumber(word) else { throw PDFAppendError("an unknown word") }
        return .number(word)
    }

    /// The name after a slash, with its #xx characters read.
    mutating func name() -> String {
        let start = pos
        let n = bytes.count
        while pos < n, !PDFParser.isWhite(bytes[pos]), !PDFParser.isDelimiter(bytes[pos]) { pos += 1 }
        var scalars = String.UnicodeScalarView()
        var i = start
        while i < pos {
            let c = bytes[i]
            if c == 0x23, pos - i >= 3, let high = PDFParser.hex(bytes[i + 1]), let low = PDFParser.hex(bytes[i + 2]) {
                scalars.append(Unicode.Scalar(UInt8(high * 16 + low)))
                i += 3
            } else {
                scalars.append(Unicode.Scalar(c))
                i += 1
            }
        }
        return String(scalars)
    }

    private mutating func dictionary(depth: Int) throws -> PDFValue {
        var items = PDFDict()
        while true {
            skip()
            guard pos < bytes.count else { throw PDFAppendError("a dictionary is not closed") }
            if starts(">>") {
                pos += 2
                return .dict(items)
            }
            guard bytes[pos] == 0x2F else { throw PDFAppendError("a dictionary key that is not a name") }
            pos += 1
            let key = name()
            items[key] = try value(depth: depth + 1)
        }
    }

    private mutating func hexString() throws -> PDFValue {
        pos += 1
        var digits: [Int] = []
        while true {
            guard pos < bytes.count else { throw PDFAppendError("a string is not closed") }
            let c = bytes[pos]
            pos += 1
            if c == 0x3E { break }
            if PDFParser.isWhite(c) { continue }
            guard let digit = PDFParser.hex(c) else { throw PDFAppendError("a string in hex with other characters") }
            digits.append(digit)
        }
        if digits.count % 2 == 1 { digits.append(0) }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            out.append(UInt8(digits[i] * 16 + digits[i + 1]))
            i += 2
        }
        return .string(out)
    }

    private mutating func literalString() throws -> PDFValue {
        let n = bytes.count
        pos += 1
        var out: [UInt8] = []
        var open = 1
        while true {
            guard pos < n else { throw PDFAppendError("a string is not closed") }
            let c = bytes[pos]
            pos += 1
            if c == 0x5C {
                guard pos < n else { throw PDFAppendError("a string is not closed") }
                let e = bytes[pos]
                pos += 1
                switch e {
                case 0x6E: out.append(10)
                case 0x72: out.append(13)
                case 0x74: out.append(9)
                case 0x62: out.append(8)
                case 0x66: out.append(12)
                case 0x30...0x37:
                    var code = Int(e) - 0x30
                    for _ in 0..<2 {
                        if pos < n, bytes[pos] >= 0x30, bytes[pos] <= 0x37 {
                            code = code * 8 + Int(bytes[pos]) - 0x30
                            pos += 1
                        } else {
                            break
                        }
                    }
                    out.append(UInt8(code & 0xFF))
                case 13:
                    // A backslash at the end of a line joins it to the next.
                    if pos < n, bytes[pos] == 10 { pos += 1 }
                case 10:
                    break
                default:
                    out.append(e)
                }
            } else if c == 0x28 {
                open += 1
                out.append(c)
            } else if c == 0x29 {
                open -= 1
                if open == 0 { return .string(out) }
                out.append(c)
            } else {
                out.append(c)
            }
        }
    }
}

/// Packing and unpacking the way PDF streams are packed (Flate, which is zlib's format).
enum PDFFlate {
    /// Undoes Flate. Foundation reads the packed bytes without zlib's two-byte header.
    static func inflate(_ packed: [UInt8]) throws -> [UInt8] {
        guard packed.count > 2 else { throw PDFAppendError("a packed stream that is too short") }
        let raw = Data(packed[2...])
        guard let out = try? (raw as NSData).decompressed(using: .zlib) else {
            throw PDFAppendError("a packed stream that does not unpack")
        }
        return [UInt8](out as Data)
    }

    /// Packs bytes as a zlib stream: header, the packed bytes, and the sum that checks them.
    static func deflate(_ raw: Data) -> Data? {
        guard !raw.isEmpty, let packed = try? (raw as NSData).compressed(using: .zlib) else { return nil }
        var out = Data([0x78, 0x9C])
        out.append(packed as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var i = 0
            let n = buffer.count
            while i < n {
                // As many bytes as can be added before the sums have to be brought back in range.
                let end = min(i + 5552, n)
                while i < end {
                    a += UInt32(buffer[i])
                    b += a
                    i += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        let sum = (b << 16) | a
        out.append(contentsOf: [UInt8(sum >> 24), UInt8((sum >> 16) & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8(sum & 0xFF)])
        return out
    }

    /// Undoes the row filters of PNG, which cross-reference streams are usually packed with.
    static func unpredict(_ data: [UInt8], _ parms: PDFDict) throws -> [UInt8] {
        let predictor = parms["Predictor"]?.int ?? 1
        if predictor == 1 { return data }
        guard predictor >= 10 else { throw PDFAppendError("a predictor that is not handled") }
        let columns = parms["Columns"]?.int ?? 1
        let colors = parms["Colors"]?.int ?? 1
        let bits = parms["BitsPerComponent"]?.int ?? 8
        guard bits == 8, columns >= 1, columns <= 1_000_000, colors >= 1, colors <= 32 else {
            throw PDFAppendError("a predictor that is not handled")
        }
        let width = columns * colors
        let step = colors
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var before = [UInt8](repeating: 0, count: width)
        var pos = 0
        while pos + 1 + width <= data.count {
            let kind = data[pos]
            var row = Array(data[(pos + 1)..<(pos + 1 + width)])
            pos += 1 + width
            switch kind {
            case 0:
                break
            case 1:
                if step < width {
                    for i in step..<width { row[i] = row[i] &+ row[i - step] }
                }
            case 2:
                for i in 0..<width { row[i] = row[i] &+ before[i] }
            case 3:
                for i in 0..<width {
                    let left = i >= step ? Int(row[i - step]) : 0
                    row[i] = row[i] &+ UInt8((left + Int(before[i])) >> 1)
                }
            case 4:
                for i in 0..<width {
                    let a = i >= step ? Int(row[i - step]) : 0
                    let b = Int(before[i])
                    let c = i >= step ? Int(before[i - step]) : 0
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let near = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    row[i] = row[i] &+ UInt8(near)
                }
            default:
                throw PDFAppendError("a row filter that is not known")
            }
            out.append(contentsOf: row)
            before = row
        }
        return out
    }
}

/// Finds the objects of a PDF file: where each one is, and the pages in their order.
final class PDFReader {
    enum Entry {
        case free
        case at(offset: Int, generation: Int)
        case packed(stream: Int, index: Int)
    }

    struct Found {
        var number: Int
        var generation: Int
        var value: PDFValue
        /// For a stream, where its bytes are in the file.
        var body: Range<Int>?
    }

    struct Leaf {
        var page: Int
        var parent: Int
        var parentGeneration: Int
    }

    let bytes: UnsafeBufferPointer<UInt8>
    private(set) var entries: [Int: Entry] = [:]
    private(set) var trailer = PDFDict()
    /// Whether the newest cross-reference of the file is a stream rather than a table.
    private(set) var newestIsStream = false
    /// Where the newest cross-reference starts.
    private(set) var start = 0
    private var cache: [Int: PDFValue] = [:]
    private var packs: [Int: (body: [UInt8], places: [(number: Int, at: Int)])] = [:]

    /// The largest object number this code is willing to believe.
    private static let most = 50_000_000

    init(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        self.bytes = bytes
        try readSections()
        if trailer["Encrypt"] != nil { throw PDFAppendError("the document is encrypted") }
    }

    // MARK: cross-reference

    private func lastStartxref() -> Int? {
        let word = Array("startxref".utf8)
        let lowest = max(0, bytes.count - 2048)
        var at = bytes.count - word.count
        while at >= lowest {
            var same = true
            for i in 0..<word.count where bytes[at + i] != word[i] {
                same = false
                break
            }
            if same { return at }
            at -= 1
        }
        return nil
    }

    private func readSections() throws {
        guard let at = lastStartxref() else { throw PDFAppendError("no startxref") }
        var p = PDFParser(bytes, at: at + 9)
        let first = try p.integer()
        start = first
        var seen = Set<Int>()
        var isFirst = true
        var waiting = [first]
        while !waiting.isEmpty {
            let offset = waiting.removeFirst()
            if seen.contains(offset) || offset < 0 || offset >= bytes.count {
                if isFirst { throw PDFAppendError("startxref points nowhere") }
                continue
            }
            seen.insert(offset)
            var p = PDFParser(bytes, at: offset)
            p.skip()
            var info: PDFDict
            var more: [Int] = []
            let isStream: Bool
            if p.starts("xref") {
                (info, more) = try readTable(&p)
                isStream = false
            } else {
                info = try readXrefStream(at: p.pos)
                isStream = true
            }
            if isFirst {
                trailer = info
                newestIsStream = isStream
                isFirst = false
            }
            // A table's own stream of entries comes before whatever is older than the table.
            if let prev = info["Prev"]?.int { more.append(prev) }
            waiting = more + waiting
        }
    }

    private func readTable(_ p: inout PDFParser) throws -> (PDFDict, [Int]) {
        p.pos += 4
        while true {
            p.skip()
            if p.starts("trailer") {
                p.pos += 7
                break
            }
            let first = try p.integer()
            let count = try p.integer()
            guard first >= 0, first <= PDFReader.most, count >= 0, count <= 10_000_000 else {
                throw PDFAppendError("a cross-reference table of an impossible size")
            }
            for i in 0..<count {
                let offset = try p.integer()
                let generation = try p.integer()
                p.skip()
                let flag = p.token()
                let number = first + i
                if entries[number] != nil { continue }
                if flag == "n" {
                    entries[number] = .at(offset: offset, generation: generation)
                } else if flag == "f" {
                    entries[number] = .free
                } else {
                    throw PDFAppendError("a cross-reference entry that is neither in use nor free")
                }
            }
        }
        guard let info = try p.value().dict else { throw PDFAppendError("a trailer that is not a dictionary") }
        var more: [Int] = []
        if let extra = info["XRefStm"]?.int { more.append(extra) }
        return (info, more)
    }

    private func readXrefStream(at offset: Int) throws -> PDFDict {
        let found = try object(at: offset, lengthsKnown: false)
        guard let info = found.value.dict, let range = found.body else {
            throw PDFAppendError("no cross-reference where startxref points")
        }
        guard let widths = info["W"]?.array, widths.count == 3 else {
            throw PDFAppendError("a cross-reference stream without field widths")
        }
        let w = widths.map { $0.int ?? 0 }
        guard w.allSatisfy({ $0 >= 0 && $0 <= 8 }), w[0] + w[1] + w[2] > 0 else {
            throw PDFAppendError("a cross-reference stream with impossible field widths")
        }
        let size = info["Size"]?.int ?? 0
        var runs = [0, size]
        if let index = info["Index"]?.array { runs = index.map { $0.int ?? 0 } }
        let body = try unpacked(info, range)
        let step = w[0] + w[1] + w[2]

        func field(_ from: Int, _ length: Int) -> Int {
            var value: UInt64 = 0
            for i in 0..<length { value = (value << 8) | UInt64(body[from + i]) }
            return Int(clamping: value)
        }

        var pos = 0
        var r = 0
        while r + 1 < runs.count {
            let first = runs[r], count = runs[r + 1]
            r += 2
            guard first >= 0, first <= PDFReader.most, count >= 0, count <= 10_000_000 else {
                throw PDFAppendError("a cross-reference stream of an impossible size")
            }
            for i in 0..<count {
                if pos + step > body.count { break }
                let a = w[0] > 0 ? field(pos, w[0]) : 1
                let b = field(pos + w[0], w[1])
                let c = w[2] > 0 ? field(pos + w[0] + w[1], w[2]) : 0
                pos += step
                let number = first + i
                if entries[number] != nil { continue }
                if a == 1 {
                    entries[number] = .at(offset: b, generation: c)
                } else if a == 2 {
                    entries[number] = .packed(stream: b, index: c)
                } else {
                    entries[number] = .free
                }
            }
        }
        return info
    }

    // MARK: objects

    /// The bytes of a stream as they were before packing.
    private func unpacked(_ info: PDFDict, _ range: Range<Int>) throws -> [UInt8] {
        let raw = Array(bytes[range])
        guard var filter = info["Filter"] else { return raw }
        var parms = info["DecodeParms"]
        if let list = filter.array {
            guard list.count == 1 else { throw PDFAppendError("a stream packed more than one way") }
            filter = list[0]
            if let each = parms?.array { parms = each.first }
        }
        guard filter.nameText == "FlateDecode" else { throw PDFAppendError("a stream packed in a way that is not handled") }
        var body = try PDFFlate.inflate(raw)
        if let number = parms?.refNumber { parms = try get(number) }
        if let table = parms?.dict { body = try PDFFlate.unpredict(body, table) }
        return body
    }

    /// The object written at [offset].
    private func object(at offset: Int, lengthsKnown: Bool = true) throws -> Found {
        guard offset >= 0, offset < bytes.count else { throw PDFAppendError("an object that is not in the file") }
        var p = PDFParser(bytes, at: offset)
        let number = try p.integer()
        let generation = try p.integer()
        try p.keyword("obj")
        let value = try p.value()
        p.skip()
        guard let info = value.dict, p.starts("stream") else {
            return Found(number: number, generation: generation, value: value, body: nil)
        }
        p.pos += 6
        if p.starts("\r\n") {
            p.pos += 2
        } else if p.starts("\n") || p.starts("\r") {
            p.pos += 1
        }
        let from = p.pos
        var length = info["Length"]
        if let other = length?.refNumber {
            // While the cross-reference itself is being read, other objects cannot be looked up yet.
            if lengthsKnown {
                length = try get(other)
            } else {
                length = nil
            }
        }
        var end: Int?
        if let count = length?.int, count >= 0, count <= bytes.count - from {
            var q = PDFParser(bytes, at: from + count)
            q.skip()
            if q.starts("endstream") { end = from + count }
        }
        if end == nil {
            // The length is missing or wrong: the stream runs to the word that closes it.
            guard var found = find("endstream", from: from) else { throw PDFAppendError("a stream that is not closed") }
            if found > from, bytes[found - 1] == 10 { found -= 1 }
            if found > from, bytes[found - 1] == 13 { found -= 1 }
            end = found
        }
        return Found(number: number, generation: generation, value: value, body: from..<(end ?? from))
    }

    private func find(_ word: String, from: Int) -> Int? {
        let wanted = Array(word.utf8)
        guard !wanted.isEmpty else { return nil }
        var at = max(from, 0)
        let last = bytes.count - wanted.count
        while at <= last {
            if bytes[at] == wanted[0] {
                var same = true
                for i in 1..<wanted.count where bytes[at + i] != wanted[i] {
                    same = false
                    break
                }
                if same { return at }
            }
            at += 1
        }
        return nil
    }

    /// Object [number], or null when the file has no such object.
    func get(_ number: Int) throws -> PDFValue {
        if let kept = cache[number] { return kept }
        var value = PDFValue.null
        switch entries[number] {
        case .at(let offset, _)?:
            let found = try object(at: offset)
            guard found.number == number else {
                throw PDFAppendError("object \(number) is not where the cross-reference says")
            }
            // A stream is known here by its dictionary alone; its bytes stay where they are.
            value = found.value
        case .packed(let stream, let index)?:
            value = try fromPack(stream, index, number)
        case .free?, nil:
            break
        }
        cache[number] = value
        return value
    }

    private func fromPack(_ packNumber: Int, _ index: Int, _ number: Int) throws -> PDFValue {
        if packs[packNumber] == nil {
            guard case .at(let offset, _)? = entries[packNumber] else {
                throw PDFAppendError("an object stream that is not in the file")
            }
            let found = try object(at: offset)
            guard let info = found.value.dict, let range = found.body else {
                throw PDFAppendError("an object stream that is not a stream")
            }
            guard let count = info["N"]?.int, let first = info["First"]?.int, count >= 0, count <= 1_000_000, first >= 0 else {
                throw PDFAppendError("an object stream without its counts")
            }
            let body = try unpacked(info, range)
            guard first <= body.count else { throw PDFAppendError("an object stream without its counts") }
            var places: [(number: Int, at: Int)] = []
            try body.withUnsafeBufferPointer { buffer in
                var p = PDFParser(buffer)
                for _ in 0..<count {
                    let n = try p.integer()
                    let off = try p.integer()
                    guard off >= 0, off <= body.count else { throw PDFAppendError("an object stream with a wrong index") }
                    places.append((n, first + off))
                }
            }
            packs[packNumber] = (body, places)
        }
        guard let pack = packs[packNumber] else { throw PDFAppendError("an object stream that is not in the file") }
        var place: Int?
        if index >= 0, index < pack.places.count, pack.places[index].number == number {
            place = pack.places[index].at
        } else {
            // Some writers get the index wrong; the number is what counts.
            place = pack.places.first { $0.number == number }?.at
        }
        guard let at = place else { throw PDFAppendError("object \(number) is not in its object stream") }
        return try pack.body.withUnsafeBufferPointer { buffer in
            var p = PDFParser(buffer, at: at)
            return try p.value()
        }
    }

    /// What a value is once references have been followed.
    func resolve(_ value: PDFValue?) throws -> PDFValue? {
        var value = value
        var hops = 0
        while let number = value?.refNumber {
            value = try get(number)
            hops += 1
            if hops > 20 { throw PDFAppendError("references that go round in a circle") }
        }
        return value
    }

    func generation(_ number: Int) -> Int {
        if case .at(_, let generation)? = entries[number] { return generation }
        return 0
    }

    // MARK: pages

    /// Every page in order, each with the part of the page tree it hangs from.
    func pages() throws -> [Leaf] {
        guard let root = try resolve(trailer["Root"])?.dict else { throw PDFAppendError("no catalogue") }
        guard case .ref(let top, let generation)? = root["Pages"] else { throw PDFAppendError("no page tree") }
        var out: [Leaf] = []
        var seen = Set<Int>()
        try walk(top, generation, parent: nil, into: &out, seen: &seen, depth: 0)
        return out
    }

    private func walk(_ number: Int, _ generation: Int, parent: (Int, Int)?, into out: inout [Leaf], seen: inout Set<Int>, depth: Int) throws {
        guard !seen.contains(number), depth <= 64 else { throw PDFAppendError("a page tree that goes round in a circle") }
        seen.insert(number)
        guard let node = try get(number).dict else { throw PDFAppendError("a page that is not a dictionary") }
        if let kids = try resolve(node["Kids"])?.array, node["Type"]?.nameText != "Page" {
            for kid in kids {
                guard case .ref(let kidNumber, let kidGeneration) = kid else {
                    throw PDFAppendError("a page tree with something else in it")
                }
                try walk(kidNumber, kidGeneration, parent: (number, generation), into: &out, seen: &seen, depth: depth + 1)
            }
        } else {
            guard let parent else { throw PDFAppendError("a page tree that is a single page") }
            out.append(Leaf(page: number, parent: parent.0, parentGeneration: parent.1))
            if out.count > 100_000 { throw PDFAppendError("too many pages") }
        }
    }
}

/// Adds pictures and pages to a PDF without writing the file anew. The file's own bytes stay as they are
/// and an update goes after them: the new objects, new versions of the few page objects that change, and
/// a cross-reference that points back at the old one. Nothing of the original is touched, so its text
/// stays exactly what it was, which a file written anew by PDFKit does not promise.
enum PDFAppend {
    /// What was written on a page, as a picture: where it goes on the page (in the page's own measure,
    /// from the lower left), its size in points of the picture, and its colours and its cover, each
    /// already packed with [PDFFlate.deflate].
    struct Picture {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var columns: Int
        var rows: Int
        var rgb: Data
        var alpha: Data
    }

    /// One page of the result: page [original] of the file, or a new page of [size] with [art] drawn on
    /// it ([art] measures from the page's top left corner, downward). Either may have a picture over it.
    struct Slot {
        var original: Int?
        var width: Double = 0
        var height: Double = 0
        var art: String = ""
        var picture: Picture?
    }

    /// A measure with at most three decimals and no needless zeros.
    static func number(_ x: Double) -> String {
        var text = String(format: "%.3f", x)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return (text.isEmpty || text == "-0") ? "0" : text
    }

    private static func ascii(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private static func write(name: String, into out: inout [UInt8]) {
        out.append(0x2F)
        for scalar in name.unicodeScalars {
            let c = UInt8(truncatingIfNeeded: scalar.value)
            if c < 0x21 || c > 0x7E || PDFParser.isDelimiter(c) || c == 0x23 {
                out.append(contentsOf: ascii(String(format: "#%02X", c)))
            } else {
                out.append(c)
            }
        }
    }

    static func write(_ value: PDFValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: ascii("null"))
        case .bool(let flag):
            out.append(contentsOf: ascii(flag ? "true" : "false"))
        case .number(let text):
            out.append(contentsOf: ascii(text))
        case .name(let text):
            write(name: text, into: &out)
        case .string(let content):
            let digits = Array("0123456789ABCDEF".utf8)
            out.append(0x3C)
            for c in content {
                out.append(digits[Int(c >> 4)])
                out.append(digits[Int(c & 15)])
            }
            out.append(0x3E)
        case .ref(let number, let generation):
            out.append(contentsOf: ascii("\(number) \(generation) R"))
        case .array(let items):
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                write(item, into: &out)
            }
            out.append(0x5D)
        case .dict(let table):
            out.append(contentsOf: ascii("<<"))
            for (i, key) in table.keys.enumerated() {
                if i > 0 { out.append(0x20) }
                write(name: key, into: &out)
                out.append(0x20)
                write(table[key] ?? .null, into: &out)
            }
            out.append(contentsOf: ascii(">>"))
        }
    }

    /// The bytes to put after the file's own for it to show [slots].
    static func update(of data: Data, slots: [Slot]) throws -> Data {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            let reader = try PDFReader(bytes)
            let work = Work(reader: reader)
            return try work.run(slots)
        }
    }

    private final class Work {
        let reader: PDFReader
        var next = 1
        /// New objects, by number: the bytes between "obj" and "endobj".
        var made: [Int: [UInt8]] = [:]
        /// Dictionaries that take the place of the ones in the file.
        var changed: [Int: PDFDict] = [:]

        init(reader: PDFReader) {
            self.reader = reader
        }

        func fresh(_ body: [UInt8]) -> PDFValue {
            let number = next
            next += 1
            made[number] = body
            return .ref(number, 0)
        }

        /// A stream object's bytes. [packed] says the body is already a zlib stream.
        func stream(_ info: PDFDict, _ body: Data, packed: Bool = false) -> [UInt8] {
            var info = info
            var content = body
            if packed {
                info["Filter"] = .name("FlateDecode")
            } else if let small = PDFFlate.deflate(body), small.count < body.count {
                info["Filter"] = .name("FlateDecode")
                content = small
            }
            info["Length"] = .number(String(content.count))
            var out: [UInt8] = []
            PDFAppend.write(.dict(info), into: &out)
            out.append(contentsOf: PDFAppend.ascii("\nstream\n"))
            out.append(contentsOf: content)
            out.append(contentsOf: PDFAppend.ascii("\nendstream"))
            return out
        }

        func text(_ info: PDFDict = PDFDict(), _ content: String) -> PDFValue {
            fresh(stream(info, Data(content.utf8)))
        }

        func editable(_ number: Int) throws -> PDFDict {
            if let kept = changed[number] { return kept }
            guard let node = try reader.get(number).dict else { throw PDFAppendError("a page that is not a dictionary") }
            changed[number] = node
            return node
        }

        func current(_ number: Int) throws -> PDFValue {
            if let kept = changed[number] { return .dict(kept) }
            return try reader.get(number)
        }

        func image(_ picture: Picture) -> PDFValue {
            var mask = PDFDict()
            mask["Type"] = .name("XObject")
            mask["Subtype"] = .name("Image")
            mask["Width"] = .number(String(picture.columns))
            mask["Height"] = .number(String(picture.rows))
            mask["ColorSpace"] = .name("DeviceGray")
            mask["BitsPerComponent"] = .number("8")
            let maskRef = fresh(stream(mask, picture.alpha, packed: true))
            var info = PDFDict()
            info["Type"] = .name("XObject")
            info["Subtype"] = .name("Image")
            info["Width"] = .number(String(picture.columns))
            info["Height"] = .number(String(picture.rows))
            info["ColorSpace"] = .name("DeviceRGB")
            info["BitsPerComponent"] = .number("8")
            info["SMask"] = maskRef
            return fresh(stream(info, picture.rgb, packed: true))
        }

        func place(_ picture: Picture, _ name: String) -> String {
            var written: [UInt8] = []
            PDFAppend.write(name: name, into: &written)
            let n = PDFAppend.number
            return "q \(n(picture.width)) 0 0 \(n(picture.height)) \(n(picture.x)) \(n(picture.y)) cm \(String(decoding: written, as: UTF8.self)) Do Q\n"
        }

        func run(_ slots: [Slot]) throws -> Data {
            let leaves = try reader.pages()
            let originals = slots.compactMap(\.original)
            guard originals == Array(0..<leaves.count) else {
                throw PDFAppendError("the pages asked for are not the pages of the file")
            }
            let size = reader.trailer["Size"]?.int ?? 0
            let highest = reader.entries.keys.max() ?? 0
            next = max(size, highest + 1, 1)
            guard next <= 60_000_000 else { throw PDFAppendError("object numbers that are impossibly large") }

            // Pictures over the file's own pages.
            for slot in slots {
                guard let original = slot.original, let picture = slot.picture else { continue }
                let leaf = leaves[original]
                var page = try editable(leaf.page)
                let pictureRef = image(picture)

                // What the page draws with, its own or handed down from the tree above it.
                var node = page
                var hops = 0
                while node["Resources"] == nil, let up = node["Parent"]?.refNumber, hops < 64 {
                    guard let above = try current(up).dict else {
                        throw PDFAppendError("a page tree that is not made of dictionaries")
                    }
                    node = above
                    hops += 1
                }
                var resources = try reader.resolve(node["Resources"])?.dict ?? PDFDict()
                var things = try reader.resolve(resources["XObject"])?.dict ?? PDFDict()
                var name = "AIPencilInk"
                while things[name] != nil { name += "x" }
                things[name] = pictureRef
                resources["XObject"] = .dict(things)
                page["Resources"] = .dict(resources)

                var before: [PDFValue] = []
                if let contents = page["Contents"] {
                    if let number = contents.refNumber {
                        if let list = try reader.get(number).array {
                            before = list
                        } else {
                            before = [contents]
                        }
                    } else if let list = contents.array {
                        before = list
                    }
                }
                for item in before where item.refNumber == nil {
                    throw PDFAppendError("page contents that are not streams")
                }
                // The page's own drawing is fenced in, so that whatever it leaves behind does not move the picture.
                if before.isEmpty {
                    page["Contents"] = .array([text(PDFDict(), place(picture, name))])
                } else {
                    let opening = text(PDFDict(), "q\n")
                    let closing = text(PDFDict(), "\nQ\n" + place(picture, name))
                    page["Contents"] = .array([opening] + before + [closing])
                }
                changed[leaf.page] = page
            }

            // New pages, each put into the tree after the page before it.
            var previous: (page: Int, parent: Int, parentGeneration: Int)?
            for slot in slots {
                if let original = slot.original {
                    let leaf = leaves[original]
                    previous = (leaf.page, leaf.parent, leaf.parentGeneration)
                    continue
                }
                guard let firstLeaf = leaves.first else { throw PDFAppendError("a document without pages") }
                let n = PDFAppend.number
                var body = "q 1 0 0 -1 0 \(n(slot.height)) cm\n\(slot.art)\nQ\n"
                var resources = PDFDict()
                if let picture = slot.picture {
                    var things = PDFDict()
                    things["AIPencilInk"] = image(picture)
                    resources["XObject"] = .dict(things)
                    body += place(picture, "AIPencilInk")
                }
                let drawing = text(PDFDict(), body)
                let parent = previous.map { ($0.parent, $0.parentGeneration) } ?? (firstLeaf.parent, firstLeaf.parentGeneration)
                let box = PDFValue.array([.number("0"), .number("0"), .number(n(slot.width)), .number(n(slot.height))])
                var info = PDFDict()
                info["Type"] = .name("Page")
                info["Parent"] = .ref(parent.0, parent.1)
                info["MediaBox"] = box
                info["CropBox"] = box
                info["Rotate"] = .number("0")
                info["Resources"] = .dict(resources)
                info["Contents"] = drawing
                var written: [UInt8] = []
                PDFAppend.write(.dict(info), into: &written)
                let pageRef = fresh(written)

                var node = try editable(parent.0)
                guard var kids = try reader.resolve(node["Kids"])?.array else {
                    throw PDFAppendError("a page tree without its list of pages")
                }
                if let previous {
                    guard let at = kids.firstIndex(where: { $0.refNumber == previous.page }) else {
                        throw PDFAppendError("a page that is not in its parent's list")
                    }
                    kids.insert(pageRef, at: at + 1)
                } else {
                    guard let at = kids.firstIndex(where: { $0.refNumber == firstLeaf.page }) else {
                        throw PDFAppendError("a page that is not in its parent's list")
                    }
                    kids.insert(pageRef, at: at)
                }
                node["Kids"] = .array(kids)
                changed[parent.0] = node
                // One more page in this part of the tree and in every part it belongs to.
                var up: Int? = parent.0
                var hops = 0
                while let number = up, hops < 64 {
                    var above = try editable(number)
                    let count = try reader.resolve(above["Count"])?.int ?? 0
                    above["Count"] = .number(String(count + 1))
                    changed[number] = above
                    up = above["Parent"]?.refNumber
                    hops += 1
                }
                previous = (pageRef.refNumber ?? 0, parent.0, parent.1)
            }

            // The update: the objects, then where they are.
            var out: [UInt8] = []
            let fileLength = reader.bytes.count
            if fileLength > 0, reader.bytes[fileLength - 1] != 10 { out.append(10) }
            var offsets: [Int: Int] = [:]
            let numbers = Set(made.keys).union(changed.keys).sorted()
            for number in numbers {
                offsets[number] = fileLength + out.count
                let generation = made[number] != nil ? 0 : reader.generation(number)
                out.append(contentsOf: PDFAppend.ascii("\(number) \(generation) obj\n"))
                if let body = made[number] {
                    out.append(contentsOf: body)
                } else if let table = changed[number] {
                    PDFAppend.write(.dict(table), into: &out)
                }
                out.append(contentsOf: PDFAppend.ascii("\nendobj\n"))
            }

            var keep = PDFDict()
            for key in ["Root", "Info", "ID"] {
                if let value = reader.trailer[key] { keep[key] = value }
            }
            keep["Prev"] = .number(String(reader.start))
            let at = fileLength + out.count
            guard at < 4_000_000_000 else { throw PDFAppendError("a file too large to add to") }
            if reader.newestIsStream {
                let own = next
                offsets[own] = at
                let listed = offsets.keys.sorted()
                var runs: [(first: Int, count: Int)] = []
                var rows: [UInt8] = []
                for number in listed {
                    if let last = runs.last, last.first + last.count == number {
                        runs[runs.count - 1].count += 1
                    } else {
                        runs.append((number, 1))
                    }
                    let offset = UInt32(offsets[number] ?? 0)
                    let generation = UInt16(clamping: changed[number] != nil ? reader.generation(number) : 0)
                    rows.append(1)
                    rows.append(contentsOf: [UInt8(offset >> 24), UInt8((offset >> 16) & 0xFF), UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF)])
                    rows.append(contentsOf: [UInt8(generation >> 8), UInt8(generation & 0xFF)])
                }
                var info = keep
                info["Type"] = .name("XRef")
                info["Size"] = .number(String(own + 1))
                info["W"] = .array([.number("1"), .number("4"), .number("2")])
                info["Index"] = .array(runs.flatMap { [PDFValue.number(String($0.first)), PDFValue.number(String($0.count))] })
                info["Length"] = .number(String(rows.count))
                out.append(contentsOf: PDFAppend.ascii("\(own) 0 obj\n"))
                PDFAppend.write(.dict(info), into: &out)
                out.append(contentsOf: PDFAppend.ascii("\nstream\n"))
                out.append(contentsOf: rows)
                out.append(contentsOf: PDFAppend.ascii("\nendstream\nendobj\n"))
            } else {
                let listed = offsets.keys.sorted()
                // Object 0 heads the list of free numbers. Saying so first is what other writers do, and
                // some readers take a table that does not start at 0 for one that is numbered wrongly.
                out.append(contentsOf: PDFAppend.ascii("xref\n0 1\n0000000000 65535 f \n"))
                var i = 0
                while i < listed.count {
                    var j = i
                    while j + 1 < listed.count, listed[j + 1] == listed[j] + 1 { j += 1 }
                    out.append(contentsOf: PDFAppend.ascii("\(listed[i]) \(j - i + 1)\n"))
                    for number in listed[i...j] {
                        let generation = changed[number] != nil ? reader.generation(number) : 0
                        out.append(contentsOf: PDFAppend.ascii(String(format: "%010ld %05ld n \n", offsets[number] ?? 0, generation)))
                    }
                    i = j + 1
                }
                var info = keep
                info["Size"] = .number(String(next))
                out.append(contentsOf: PDFAppend.ascii("trailer\n"))
                PDFAppend.write(.dict(info), into: &out)
                out.append(10)
            }
            out.append(contentsOf: PDFAppend.ascii("startxref\n\(at)\n%%EOF\n"))
            return Data(out)
        }
    }
}
