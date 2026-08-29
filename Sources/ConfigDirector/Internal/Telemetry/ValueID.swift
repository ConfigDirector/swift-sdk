import CryptoKit
import Foundation

enum ValueID {
    /// How many bytes of the digest make up a value id.
    private static let digestBytes = 16

    /// The length every value id is padded to: `ceil(128 / log2(62))`, the number of base62 digits
    /// `digestBytes` bytes can produce.
    private static let length = 22

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Derives the identifier ConfigDirector knows `value` by, so that values too large to report
    /// inline can still be counted.
    ///
    /// Every ConfigDirector SDK derives the same id for the same value: the first `digestBytes` bytes
    /// of its SHA-256 digest, in base62.
    static func make(for value: String) -> String {
        base62(Array(SHA256.hash(data: Data(value.utf8)).prefix(digestBytes)))
    }

    private static func base62(_ bytes: [UInt8]) -> String {
        var remaining = bytes
        var digits: [Character] = []

        while let firstSignificant = remaining.firstIndex(where: { $0 != 0 }) {
            remaining.removeFirst(firstSignificant)

            var remainder = 0
            for index in remaining.indices {
                let carried = remainder << 8 | Int(remaining[index])
                remaining[index] = UInt8(carried / alphabet.count)
                remainder = carried % alphabet.count
            }
            digits.append(alphabet[remainder])
        }

        return String(repeating: "0", count: max(0, length - digits.count)) + String(digits.reversed())
    }
}
