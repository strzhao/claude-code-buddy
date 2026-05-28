import Foundation
import CryptoKit

// MARK: - Digest hex helper

extension Digest {
    var hexString: String {
        compactMap { String(format: "%02x", $0) }.joined()
    }
}
