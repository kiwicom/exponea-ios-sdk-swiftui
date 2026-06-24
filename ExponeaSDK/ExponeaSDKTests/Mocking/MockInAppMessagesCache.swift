//
//  MockInAppMessagesCache.swift
//  ExponeaSDKTests
//
//  Created by Panaxeo on 05/12/2019.
//  Copyright © 2019 Exponea. All rights reserved.
//

@testable import ExponeaSDK

final class MockInAppMessagesCache: InAppMessagesCacheType {
    @Atomic private var messages: [InAppMessage] = []
    @Atomic private var images: [String: Data] = [:]
    @Atomic private var timestamp: TimeInterval = 0
    @Atomic private var saveImageDataCallCounter: Int = 0

    func saveInAppMessages(inAppMessages: [InAppMessage]) {
        _messages.changeValue { $0 = inAppMessages }
    }

    func getInAppMessages() -> [InAppMessage] {
        return messages
    }

    func getInAppMessagesTimestamp() -> TimeInterval {
        return timestamp
    }

    func setInAppMessagesTimestamp(_ timestamp: TimeInterval) {
        _timestamp.changeValue { $0 = timestamp }
    }

    func deleteImages(except: [String]) {
        _images.changeValue { $0 = $0.filter { except.contains($0.key) } }
    }

    func hasImageData(at imageUrl: String) -> Bool {
        return images[imageUrl] != nil
    }

    func saveImageData(at imageUrl: String, data: Data) {
        _images.changeValue { $0[imageUrl] = data }
        _saveImageDataCallCounter.changeValue { $0 += 1 }
    }

    func getImageData(at imageUrl: String) -> Data? {
        return images[imageUrl]
    }

    func clear() {
        _images.changeValue { $0 = [:] }
        _messages.changeValue { $0 = [] }
    }

    func getImageDownloadCount() -> Int {
        return saveImageDataCallCounter
    }
}
