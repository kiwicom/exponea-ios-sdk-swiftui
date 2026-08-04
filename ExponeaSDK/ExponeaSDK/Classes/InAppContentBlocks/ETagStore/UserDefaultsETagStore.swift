//
//  UserDefaultsETagStore.swift
//  ExponeaSDK
//
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation

final class UserDefaultsETagStore: InAppContentBlocksETagStore {

    private static let keyPrefix = "exponea_icb_etag_"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func store(etag: String, forKey key: String) {
        guard !key.isEmpty else {
            Exponea.logger.log(.verbose, message: "ICB ETag store: skipped — empty key")
            return
        }
        defaults.set(etag, forKey: Self.keyPrefix + key)
        Exponea.logger.log(.verbose, message: "ICB ETag stored: key=\(key.prefix(16))… etag=\(etag.prefix(16))…")
    }

    func retrieve(forKey key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let value = defaults.string(forKey: Self.keyPrefix + key)
        Exponea.logger.log(
            .verbose,
            message: "ICB ETag retrieve: key=\(key.prefix(16))… result=\(value?.prefix(16).description ?? "nil")"
        )
        return value
    }

    func remove(forKey key: String) {
        guard !key.isEmpty else { return }
        defaults.removeObject(forKey: Self.keyPrefix + key)
    }

    func clearAll() {
        let allKeys = defaults.dictionaryRepresentation().keys
        allKeys.filter { $0.hasPrefix(Self.keyPrefix) }
               .forEach { defaults.removeObject(forKey: $0) }
    }
}
