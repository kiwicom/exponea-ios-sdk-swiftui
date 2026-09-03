//
//  UserDefaultsETagStoreSpec.swift
//  ExponeaSDKTests
//
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation
import Quick
import Nimble
@testable import ExponeaSDK

final class UserDefaultsETagStoreSpec: QuickSpec {
    override func spec() {
        var suiteName: String!
        var defaults: UserDefaults!
        var store: UserDefaultsETagStore!

        beforeEach {
            suiteName = "test_etag_\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            store = UserDefaultsETagStore(defaults: defaults)
        }

        afterEach {
            defaults.removeSuite(named: suiteName)
        }

        describe("store and retrieve") {
            it("returns a stored ETag for the same key") {
                store.store(etag: "\"abc123\"", forKey: "key1")
                expect(store.retrieve(forKey: "key1")).to(equal("\"abc123\""))
            }

            it("returns nil when no ETag has been stored for the key") {
                expect(store.retrieve(forKey: "nonexistent")).to(beNil())
            }

            it("overwrites a previously stored ETag with a new value") {
                store.store(etag: "\"v1\"", forKey: "key1")
                store.store(etag: "\"v2\"", forKey: "key1")
                expect(store.retrieve(forKey: "key1")).to(equal("\"v2\""))
            }
        }

        describe("store no-op on empty key") {
            it("does not write anything when key is empty") {
                store.store(etag: "\"abc\"", forKey: "")
                expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("exponea_icb_etag_") }).to(beEmpty())
            }

            it("returns nil for an empty key") {
                expect(store.retrieve(forKey: "")).to(beNil())
            }
        }

        describe("remove") {
            it("removes a single stored ETag without affecting others") {
                store.store(etag: "\"a\"", forKey: "key1")
                store.store(etag: "\"b\"", forKey: "key2")
                store.remove(forKey: "key1")
                expect(store.retrieve(forKey: "key1")).to(beNil())
                expect(store.retrieve(forKey: "key2")).to(equal("\"b\""))
            }

            it("is a no-op for an empty key") {
                store.store(etag: "\"a\"", forKey: "key1")
                store.remove(forKey: "")
                expect(store.retrieve(forKey: "key1")).to(equal("\"a\""))
            }

            it("is a no-op when the key has no stored ETag") {
                store.remove(forKey: "nonexistent")
                expect(store.retrieve(forKey: "nonexistent")).to(beNil())
            }
        }

        describe("clearAll") {
            it("removes all keys with the store prefix") {
                store.store(etag: "\"a\"", forKey: "key1")
                store.store(etag: "\"b\"", forKey: "key2")
                store.clearAll()
                expect(store.retrieve(forKey: "key1")).to(beNil())
                expect(store.retrieve(forKey: "key2")).to(beNil())
            }

            it("does not remove keys that do not have the store prefix") {
                defaults.set("unrelated", forKey: "some_other_key")
                store.store(etag: "\"a\"", forKey: "key1")
                store.clearAll()
                expect(defaults.string(forKey: "some_other_key")).to(equal("unrelated"))
            }
        }

        describe("cacheKey") {
            it("produces the same key for identical inputs") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "abc"], blockIds: ["b1"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "abc"], blockIds: ["b1"])
                expect(k1).to(equal(k2))
            }

            it("produces a different key for different customerIds") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "abc"], blockIds: ["b1"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "xyz"], blockIds: ["b1"])
                expect(k1).toNot(equal(k2))
            }

            it("produces a different key for a different projectToken") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "proj1", customerIds: ["id": "abc"], blockIds: ["b1"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "proj2", customerIds: ["id": "abc"], blockIds: ["b1"])
                expect(k1).toNot(equal(k2))
            }

            it("is key-order independent — same ids in different dictionary order produce the same key") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "p", customerIds: ["a": "1", "b": "2"], blockIds: ["b1"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "p", customerIds: ["b": "2", "a": "1"], blockIds: ["b1"])
                expect(k1).to(equal(k2))
            }

            it("produces a different key for different blockIds") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "abc"], blockIds: ["block-1"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "proj", customerIds: ["id": "abc"], blockIds: ["block-1", "block-2"])
                expect(k1).toNot(equal(k2))
            }

            it("is blockIds-order independent — same block ids in different order produce the same key") {
                let k1 = UserDefaultsETagStore.cacheKey(projectToken: "p", customerIds: ["id": "abc"], blockIds: ["b1", "b2"])
                let k2 = UserDefaultsETagStore.cacheKey(projectToken: "p", customerIds: ["id": "abc"], blockIds: ["b2", "b1"])
                expect(k1).to(equal(k2))
            }
        }
    }
}
