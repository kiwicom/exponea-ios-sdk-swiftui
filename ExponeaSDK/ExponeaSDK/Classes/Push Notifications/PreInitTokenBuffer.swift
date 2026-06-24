//
//  PreInitTokenBuffer.swift
//  ExponeaSDK
//
//  Buffers APNs push tokens that arrive BEFORE
//  `Exponea.configure()` completes so they survive:
//    1. the normal pre-init window (covered today by
//       `ExpoInitManager.actionBlocks`, which is in-memory only), and
//    2. a process crash during that window, which loses the in-memory
//       action queue and, prior to this change, dropped the token until
//       the host app next re-registered with APNs.
//
//  Semantics: we persist only the LATEST token (overwrite on each
//  buffer call). On a successful `PushNotificationManager.init` drain
//  we return and clear the persisted entry. `handlePushTokenRegistered`
//  is idempotent for unchanged tokens (see onTokenChange dedup in
//  TrackingManager), so if the regular `ExpoInitManager` path also
//  fires after configure, a duplicate call is harmless.
//

import Foundation
#if canImport(ExponeaSDKShared)
import ExponeaSDKShared
#endif

internal struct BufferedPushToken: Codable, Equatable {
    let token: String
    let receivedAt: TimeInterval
}

internal protocol PreInitTokenBufferStorage {
    func readBufferedToken() -> BufferedPushToken?
    func writeBufferedToken(_ entry: BufferedPushToken)
    func clearBufferedToken()
}

/// Default storage bound to the SDK's own UserDefaults suite. We do NOT
/// use the host app-group suite because the app group is configured
/// inside `Configuration` and is therefore not known until after
/// `Exponea.configure()` - i.e. exactly too late for pre-init buffering.
internal final class UserDefaultsPreInitTokenBufferStorage: PreInitTokenBufferStorage {

    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = {
            if UserDefaults(suiteName: Constants.General.userDefaultsSuite) == nil {
                UserDefaults.standard.addSuite(named: Constants.General.userDefaultsSuite)
            }
            return UserDefaults(suiteName: Constants.General.userDefaultsSuite) ?? .standard
        }(),
        key: String = Constants.General.preInitPushTokenBufferKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func readBufferedToken() -> BufferedPushToken? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(BufferedPushToken.self, from: data)
    }

    func writeBufferedToken(_ entry: BufferedPushToken) {
        guard let data = try? JSONEncoder().encode(entry) else {
            Exponea.logger.log(
                .error,
                message: "Failed to encode pre-init push token; buffer write skipped."
            )
            return
        }
        userDefaults.set(data, forKey: key)
    }

    func clearBufferedToken() {
        userDefaults.removeObject(forKey: key)
    }
}

internal final class PreInitTokenBuffer {

    /// Shared instance used by production callers. Tests inject a custom
    /// storage via `init(storage:queueLabel:)` to avoid touching the real
    /// UserDefaults suite.
    static let shared = PreInitTokenBuffer()

    private let storage: PreInitTokenBufferStorage
    private let queue: DispatchQueue

    init(
        storage: PreInitTokenBufferStorage = UserDefaultsPreInitTokenBufferStorage(),
        queueLabel: String = "com.exponea.preInitTokenBuffer"
    ) {
        self.storage = storage
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// Stores the most recent pre-init push token, overwriting any
    /// previously buffered entry. Safe to call from any thread.
    func buffer(token: String, receivedAt: TimeInterval = Date().timeIntervalSince1970) {
        guard !token.isEmpty else { return }
        queue.sync {
            storage.writeBufferedToken(BufferedPushToken(token: token, receivedAt: receivedAt))
        }
    }

    /// Returns and clears the most recent persisted pre-init token, if
    /// any. Idempotent: subsequent calls return `nil` until a new token
    /// is buffered.
    @discardableResult
    func drain() -> BufferedPushToken? {
        return queue.sync {
            let entry = storage.readBufferedToken()
            storage.clearBufferedToken()
            return entry
        }
    }

    /// Non-destructive inspection - used by tests only. Not exposed
    /// publicly to keep the buffer's observable surface small.
    func peek() -> BufferedPushToken? {
        return queue.sync {
            return storage.readBufferedToken()
        }
    }
}
