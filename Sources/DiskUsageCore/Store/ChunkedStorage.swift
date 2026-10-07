import Foundation

/// 要素を固定長の塊に分けて持つ、追記専用の配列。
///
/// 伸ばすときに既存の要素を複製しないため、1000 万件規模でも一時的に倍のメモリを使わない。
/// 要素の場所は解放まで動かない。参照型で同期を持たないため、利用側（ScanStore）のロックの中で
/// 読み書きする。書き込みが終わった後（確定後）は、ロックの外から読むだけなら安全。
final class ChunkedBuffer<Element> {
    private static var chunkShift: Int { 16 }
    private static var chunkCapacity: Int { 1 << chunkShift }

    private var chunks: [UnsafeMutablePointer<Element>] = []
    private(set) var count = 0

    init() {}

    deinit {
        for (i, chunk) in chunks.enumerated() {
            chunk.deinitialize(count: min(Self.chunkCapacity, count - i * Self.chunkCapacity))
            chunk.deallocate()
        }
    }

    var isEmpty: Bool { count == 0 }

    func contains(index: Int) -> Bool {
        index >= 0 && index < count
    }

    func append(_ element: Element) {
        let offset = count & (Self.chunkCapacity - 1)
        if offset == 0 {
            chunks.append(.allocate(capacity: Self.chunkCapacity))
        }
        (chunks[count >> Self.chunkShift] + offset).initialize(to: element)
        count += 1
    }

    subscript(index: Int) -> Element {
        unsafeAddress { UnsafePointer(address(index)) }
        unsafeMutableAddress { address(index) }
    }

    private func address(_ index: Int) -> UnsafeMutablePointer<Element> {
        precondition(index >= 0 && index < count, "範囲外の添字")
        return chunks[index >> Self.chunkShift] + (index & (Self.chunkCapacity - 1))
    }
}

/// 項目名の UTF-8 バイト列を、固定長の塊にまとめて持つ追記専用の領域。
///
/// 名前ごとに String を持つと、短くない名前はそれぞれ別のヒープ領域になる。ここでは塊の中に
/// 詰めて置き、ノードには位置だけを持たせる。書き込んだバイト列は解放まで動かず変わらないため、
/// ロックの中で取り出した `bytes(_:)` は、ストアが生きている間はロックの外でも読める。
final class NameStorage {
    /// 名前の位置。塊の番号・塊の中の開始位置・長さ（バイト）。
    struct Location: Equatable {
        var chunk: UInt32
        var offset: UInt16
        var length: UInt16
    }

    /// 1つの塊の大きさ。名前の上限（UInt16 の最大値）以上にする
    private static var chunkCapacity: Int { 1 << 16 }

    private var chunks: [UnsafeMutablePointer<UInt8>] = []
    private var used = NameStorage.chunkCapacity

    init() {}

    deinit {
        for chunk in chunks {
            chunk.deallocate()
        }
    }

    /// 名前を書き込んで位置を返す。
    ///
    /// 名前は1成分あたり 255 バイト程度（NAME_MAX）に制限されるため、65,535 バイトを超える名前は
    /// 実際には現れない。超えた場合は末尾を切り詰める（切れた文字は表示時に置換文字になる）。
    func append(_ name: String) -> Location {
        var name = name
        return name.withUTF8 { bytes in
            let length = min(bytes.count, Int(UInt16.max))
            if chunks.isEmpty || used + length > Self.chunkCapacity {
                chunks.append(.allocate(capacity: Self.chunkCapacity))
                used = 0
            }
            if length > 0, let source = bytes.baseAddress {
                (chunks[chunks.count - 1] + used).initialize(from: source, count: length)
            }
            let location = Location(chunk: UInt32(chunks.count - 1), offset: UInt16(used), length: UInt16(length))
            used += length
            return location
        }
    }

    func bytes(_ location: Location) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: chunks[Int(location.chunk)] + Int(location.offset), count: Int(location.length))
    }

    func string(_ location: Location) -> String {
        String(decoding: bytes(location), as: UTF8.self)
    }

    /// バイト列（Unicode のコードポイント順）で比べる。負なら lhs が先。
    static func compare(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: UnsafeBufferPointer<UInt8>) -> Int {
        let common = min(lhs.count, rhs.count)
        if common > 0, let l = lhs.baseAddress, let r = rhs.baseAddress {
            let order = memcmp(l, r, common)
            if order != 0 {
                return order < 0 ? -1 : 1
            }
        }
        return lhs.count == rhs.count ? 0 : (lhs.count < rhs.count ? -1 : 1)
    }
}
