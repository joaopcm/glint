import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// FIPS 180-4 section 6.2 and RFC 2104, with a pure-Swift implementation because CryptoKit isn't on Linux.
enum SHA256 {
    private static let blockSize = 64

    private static let roundConstants: ContiguousArray<UInt32> = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    struct SoftwareHasher {
        private var h0: UInt32 = 0x6a09e667
        private var h1: UInt32 = 0xbb67ae85
        private var h2: UInt32 = 0x3c6ef372
        private var h3: UInt32 = 0xa54ff53a
        private var h4: UInt32 = 0x510e527f
        private var h5: UInt32 = 0x9b05688c
        private var h6: UInt32 = 0x1f83d9ab
        private var h7: UInt32 = 0x5be0cd19
        private var tail = ContiguousArray<UInt8>(repeating: 0, count: blockSize)
        private var tailCount = 0
        private var totalBytes: UInt64 = 0

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            totalBytes &+= UInt64(bytes.count)
            var offset = 0

            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                roundConstants.withUnsafeBufferPointer { k in
                    if tailCount > 0 {
                        let needed = blockSize - tailCount
                        if bytes.count < needed {
                            tail.withUnsafeMutableBytes { dst in
                                dst.baseAddress!.advanced(by: tailCount).copyMemory(from: base, byteCount: bytes.count)
                            }
                            tailCount += bytes.count
                            return
                        }
                        tail.withUnsafeMutableBytes { dst in
                            dst.baseAddress!.advanced(by: tailCount).copyMemory(from: base, byteCount: needed)
                        }
                        let localTail = tail
                        localTail.withUnsafeBytes { compressBlock(at: $0.baseAddress!, w: w, k: k) }
                        tailCount = 0
                        offset = needed
                    }

                    while offset + blockSize <= bytes.count {
                        compressBlock(at: base.advanced(by: offset), w: w, k: k)
                        offset += blockSize
                    }

                    let remaining = bytes.count - offset
                    if remaining > 0 {
                        tail.withUnsafeMutableBytes { dst in
                            dst.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: remaining)
                        }
                        tailCount = remaining
                    }
                }
            }
        }

        mutating func finalize() -> [UInt8] {
            let bitLength = totalBytes &* 8
            tail[tailCount] = 0x80
            tailCount += 1

            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                roundConstants.withUnsafeBufferPointer { k in
                    if tailCount > blockSize - 8 {
                        for i in tailCount..<blockSize { tail[i] = 0 }
                        let localTail = tail
                        localTail.withUnsafeBytes { compressBlock(at: $0.baseAddress!, w: w, k: k) }
                        tailCount = 0
                    }
                    for i in tailCount..<(blockSize - 8) { tail[i] = 0 }
                    let bigBits = bitLength.bigEndian
                    withUnsafeBytes(of: bigBits) { src in
                        for i in 0..<8 { tail[blockSize - 8 + i] = src[i] }
                    }
                    let localTail = tail
                    localTail.withUnsafeBytes { compressBlock(at: $0.baseAddress!, w: w, k: k) }
                }
            }

            let words = (h0.bigEndian, h1.bigEndian, h2.bigEndian, h3.bigEndian, h4.bigEndian, h5.bigEndian, h6.bigEndian, h7.bigEndian)
            return [UInt8](unsafeUninitializedCapacity: 32) { out, initialized in
                withUnsafeBytes(of: words) { src in
                    UnsafeMutableRawBufferPointer(out).copyMemory(from: src)
                }
                initialized = 32
            }
        }

        @inline(__always)
        private mutating func compressBlock(
            at block: UnsafeRawPointer,
            w: UnsafeMutableBufferPointer<UInt32>,
            k: UnsafeBufferPointer<UInt32>
        ) {
            for i in 0..<16 {
                w[i] = block.loadUnaligned(fromByteOffset: i &* 4, as: UInt32.self).bigEndian
            }
            for i in 16..<64 {
                let w15 = w[i &- 15]
                let w2 = w[i &- 2]
                let s0 = rotateRight(w15, 7) ^ rotateRight(w15, 18) ^ (w15 >> 3)
                let s1 = rotateRight(w2, 17) ^ rotateRight(w2, 19) ^ (w2 >> 10)
                w[i] = w[i &- 16] &+ s0 &+ w[i &- 7] &+ s1
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for i in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ k[i] &+ w[i]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
            h5 &+= f
            h6 &+= g
            h7 &+= h
        }
    }

    static func softwareHash(_ message: [UInt8]) -> [UInt8] {
        var hasher = SoftwareHasher()
        message.withUnsafeBytes { hasher.update($0) }
        return hasher.finalize()
    }

    static func softwareHash(_ data: Data) -> [UInt8] {
        var hasher = SoftwareHasher()
        for region in data.regions {
            region.withUnsafeBytes { hasher.update($0) }
        }
        return hasher.finalize()
    }

    static func softwareHMAC(key: [UInt8], message: [UInt8]) -> [UInt8] {
        message.withUnsafeBytes { softwareHMAC(key: key, messageBytes: $0) }
    }

    private static func softwareHMAC(key: [UInt8], messageBytes: UnsafeRawBufferPointer) -> [UInt8] {
        let normalizedKey = key.count > blockSize ? softwareHash(key) : key
        var ipad = ContiguousArray<UInt8>(repeating: 0x36, count: blockSize)
        var opad = ContiguousArray<UInt8>(repeating: 0x5c, count: blockSize)
        for i in 0..<normalizedKey.count {
            ipad[i] ^= normalizedKey[i]
            opad[i] ^= normalizedKey[i]
        }
        var inner = SoftwareHasher()
        ipad.withUnsafeBytes { inner.update($0) }
        inner.update(messageBytes)
        let innerDigest = inner.finalize()

        var outer = SoftwareHasher()
        opad.withUnsafeBytes { outer.update($0) }
        innerDigest.withUnsafeBytes { outer.update($0) }
        return outer.finalize()
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(CryptoKit.SHA256.hash(data: message))
        #else
        return softwareHash(message)
        #endif
    }

    static func hash(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        for region in data.regions {
            region.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return Array(hasher.finalize())
        #else
        return softwareHash(data)
        #endif
    }

    static func hash(_ utf8: String.UTF8View) -> [UInt8] {
        if let digest = utf8.withContiguousStorageIfAvailable({ buffer -> [UInt8] in
            #if canImport(CryptoKit)
            return Array(CryptoKit.SHA256.hash(data: UnsafeRawBufferPointer(buffer)))
            #else
            var hasher = SoftwareHasher()
            hasher.update(UnsafeRawBufferPointer(buffer))
            return hasher.finalize()
            #endif
        }) {
            return digest
        }
        return hash(Array(utf8))
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        let symmetricKey = SymmetricKey(data: key)
        return Array(HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: symmetricKey))
        #else
        return softwareHMAC(key: key, message: message)
        #endif
    }

    static func hmac(key: [UInt8], message: String.UTF8View) -> [UInt8] {
        if let result = message.withContiguousStorageIfAvailable({ buffer -> [UInt8] in
            #if canImport(CryptoKit)
            let symmetricKey = SymmetricKey(data: key)
            return Array(HMAC<CryptoKit.SHA256>.authenticationCode(for: UnsafeRawBufferPointer(buffer), using: symmetricKey))
            #else
            return softwareHMAC(key: key, messageBytes: UnsafeRawBufferPointer(buffer))
            #endif
        }) {
            return result
        }
        return hmac(key: key, message: Array(message))
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 &- count))
    }
}

extension Array where Element == UInt8 {
    private static let hexDigits = ContiguousArray("0123456789abcdef".utf8)

    var hex: String {
        guard !isEmpty else { return "" }
        return Self.hexDigits.withUnsafeBufferPointer { digits in
            String(unsafeUninitializedCapacity: count * 2) { out in
                withUnsafeBufferPointer { bytes in
                    for i in 0..<bytes.count {
                        let byte = bytes[i]
                        out[i * 2] = digits[Int(byte >> 4)]
                        out[i * 2 + 1] = digits[Int(byte & 0x0f)]
                    }
                }
                return count * 2
            }
        }
    }
}
