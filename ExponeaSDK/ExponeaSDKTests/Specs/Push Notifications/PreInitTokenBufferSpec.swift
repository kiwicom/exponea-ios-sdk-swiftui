//
//  PreInitTokenBufferSpec.swift
//  ExponeaSDKTests
//
//  Unit tests for the pre-init APNs token buffer.
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK

/// In-memory implementation used by the unit tests so each spec sees a
/// clean storage without touching the real UserDefaults suite.
private final class InMemoryBufferStorage: PreInitTokenBufferStorage {
    private var entry: BufferedPushToken?
    private let lock = NSRecursiveLock()

    func readBufferedToken() -> BufferedPushToken? {
        lock.lock(); defer { lock.unlock() }
        return entry
    }

    func writeBufferedToken(_ entry: BufferedPushToken) {
        lock.lock(); defer { lock.unlock() }
        self.entry = entry
    }

    func clearBufferedToken() {
        lock.lock(); defer { lock.unlock() }
        self.entry = nil
    }
}

final class PreInitTokenBufferSpec: QuickSpec {
    override func spec() {
        describe("PreInitTokenBuffer.buffer + drain") {
            var storage: InMemoryBufferStorage!
            var buffer: PreInitTokenBuffer!

            beforeEach {
                storage = InMemoryBufferStorage()
                buffer = PreInitTokenBuffer(storage: storage, queueLabel: "test")
            }

            it("returns nil when no token was buffered") {
                expect(buffer.drain()).to(beNil())
            }

            it("persists the most recent token across drain calls") {
                buffer.buffer(token: "token-alpha", receivedAt: 100)
                let drained = buffer.drain()
                expect(drained?.token).to(equal("token-alpha"))
                expect(drained?.receivedAt).to(beCloseTo(100, within: 0.0001))
            }

            it("clears the persisted entry after drain") {
                buffer.buffer(token: "token-alpha", receivedAt: 100)
                _ = buffer.drain()
                expect(buffer.drain()).to(beNil())
                expect(buffer.peek()).to(beNil())
            }

            it("overwrites a previously buffered token") {
                buffer.buffer(token: "old-token", receivedAt: 100)
                buffer.buffer(token: "new-token", receivedAt: 200)
                let drained = buffer.drain()
                expect(drained?.token).to(equal("new-token"))
                expect(drained?.receivedAt).to(beCloseTo(200, within: 0.0001))
            }

            it("ignores empty-string buffer writes") {
                buffer.buffer(token: "", receivedAt: 100)
                expect(buffer.peek()).to(beNil())
                expect(buffer.drain()).to(beNil())
            }
        }

        describe("UserDefaultsPreInitTokenBufferStorage round-trip") {
            // Crash-recovery needs actual persistence across buffer
            // instances. We instantiate a dedicated UserDefaults suite
            // to avoid leaking test state into the SDK suite.
            let suiteName = "com.exponea.tests.preInitTokenBuffer"
            var defaults: UserDefaults!
            let key = "test-key"

            beforeEach {
                defaults = UserDefaults(suiteName: suiteName)
                defaults.removePersistentDomain(forName: suiteName)
            }

            afterEach {
                defaults.removePersistentDomain(forName: suiteName)
            }

            it("survives a new storage instance pointing at the same defaults") {
                let storageA = UserDefaultsPreInitTokenBufferStorage(userDefaults: defaults, key: key)
                storageA.writeBufferedToken(BufferedPushToken(token: "crash-token", receivedAt: 42))

                // simulate a fresh process attach
                let storageB = UserDefaultsPreInitTokenBufferStorage(userDefaults: defaults, key: key)
                let read = storageB.readBufferedToken()
                expect(read?.token).to(equal("crash-token"))
                expect(read?.receivedAt).to(beCloseTo(42, within: 0.0001))
            }

            it("returns nil for missing keys and clears cleanly") {
                let storage = UserDefaultsPreInitTokenBufferStorage(userDefaults: defaults, key: key)
                expect(storage.readBufferedToken()).to(beNil())
                storage.writeBufferedToken(BufferedPushToken(token: "t", receivedAt: 1))
                storage.clearBufferedToken()
                expect(storage.readBufferedToken()).to(beNil())
            }
        }

        describe("clearUserDefaults alignment — SDK suite key removal") {
            let sdkSuite = ExponeaSDK.Constants.General.userDefaultsSuite
            let bufferKey = ExponeaSDK.Constants.General.preInitPushTokenBufferKey

            afterEach {
                UserDefaults(suiteName: sdkSuite)?.removeObject(forKey: bufferKey)
            }

            it("buffered token is removed when the SDK suite key is explicitly cleared (mirrors clearUserDefaults path)") {
                let storage = UserDefaultsPreInitTokenBufferStorage(
                    userDefaults: UserDefaults(suiteName: sdkSuite)!,
                    key: bufferKey
                )
                storage.writeBufferedToken(BufferedPushToken(token: "stale-token", receivedAt: 999))
                expect(storage.readBufferedToken()?.token).to(equal("stale-token"))

                // Replicate the cleanup that clearUserDefaults performs:
                UserDefaults(suiteName: sdkSuite)?
                    .removeObject(forKey: bufferKey)

                expect(storage.readBufferedToken()).to(beNil())
            }

            it("buffered token is removed when the entire SDK suite is wiped (no-app-group path)") {
                let storage = UserDefaultsPreInitTokenBufferStorage(
                    userDefaults: UserDefaults(suiteName: sdkSuite)!,
                    key: bufferKey
                )
                storage.writeBufferedToken(BufferedPushToken(token: "stale-token", receivedAt: 999))
                expect(storage.readBufferedToken()?.token).to(equal("stale-token"))

                // Replicate the no-app-group branch that wipes all keys:
                if let defaults = UserDefaults(suiteName: sdkSuite) {
                    for key in defaults.dictionaryRepresentation().keys where key != "isStopped" {
                        defaults.removeObject(forKey: key)
                    }
                }

                expect(storage.readBufferedToken()).to(beNil())
            }
        }
    }
}
