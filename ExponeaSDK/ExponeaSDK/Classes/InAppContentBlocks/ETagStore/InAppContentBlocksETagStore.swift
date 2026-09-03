//
//  InAppContentBlocksETagStore.swift
//  ExponeaSDK
//
//  Copyright © 2026 Exponea. All rights reserved.
//

import CryptoKit
import Foundation

protocol InAppContentBlocksETagStore: AnyObject {
    /// Builds a cache key from project token, customer IDs, and block IDs.
    static func cacheKey(projectToken: String, customerIds: [String: String], blockIds: [String]) -> String

    /// Persists `etag` for the given `key`. No-op if `key` is empty.
    func store(etag: String, forKey key: String)

    /// Returns the stored ETag for `key`, or `nil` if none exists.
    func retrieve(forKey key: String) -> String?

    /// Removes the ETag stored under `key`. No-op if the key is absent or empty.
    func remove(forKey key: String)

    /// Removes all ETag entries managed by this store.
    func clearAll()
}

extension InAppContentBlocksETagStore {
    static func cacheKey(projectToken: String, customerIds: [String: String], blockIds: [String]) -> String {
        let customerJson = (try? JSONSerialization.data(
            withJSONObject: customerIds,
            options: [.sortedKeys]
        )) ?? Data()
        let blockIdsPart = Data(blockIds.sorted().joined(separator: ",").utf8)
        var hasher = SHA256()
        hasher.update(data: customerJson)
        hasher.update(data: blockIdsPart)
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(projectToken)_\(hex)"
    }
}
