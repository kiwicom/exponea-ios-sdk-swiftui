//
//  Data+ImageFormat.swift
//  ExponeaSDKShared
//
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation

extension Data {
    /// GIF87a and GIF89a both start with "GIF8".
    public var isGif: Bool {
        starts(with: [0x47, 0x49, 0x46, 0x38])
    }

    /// Any WebP variant: RIFF container (bytes 0-3) + WEBP signature (bytes 8-11).
    /// Covers VP8 (lossy), VP8L (lossless), and VP8X (extended/animated).
    var isWebP: Bool {
        count >= 12
            && self[startIndex]      == 0x52
            && self[startIndex + 1]  == 0x49
            && self[startIndex + 2]  == 0x46
            && self[startIndex + 3]  == 0x46
            && self[startIndex + 8]  == 0x57
            && self[startIndex + 9]  == 0x45
            && self[startIndex + 10] == 0x42
            && self[startIndex + 11] == 0x50
    }

    /// Extended WebP (VP8X chunk at bytes 12-15). VP8X covers animation,
    /// alpha, ICC, and EXIF. False-positive on non-animated VP8X is harmless:
    /// CGImageSource produces a single-frame source and the animated decoder
    /// handles it correctly. On iOS 14+ CGImageSource supports WebP natively.
    public var isExtendedWebP: Bool {
        isWebP
            && count >= 16
            && self[startIndex + 12] == 0x56
            && self[startIndex + 13] == 0x50
            && self[startIndex + 14] == 0x38
            && self[startIndex + 15] == 0x58
    }
}

