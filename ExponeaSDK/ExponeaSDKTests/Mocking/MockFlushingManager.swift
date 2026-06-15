//
//  MockFlushingManager.swift
//  ExponeaSDKTests
//
//  Created by Panaxeo on 13/12/2019.
//  Copyright © 2019 Exponea. All rights reserved.
//

import Foundation
@testable import ExponeaSDK

internal class MockFlushingManager: FlushingManagerType {
    var inAppRefreshCallback: ExponeaSDK.EmptyBlock?

    /// Optional caller-supplied `FlushResult` returned from `flushData(isFromIdentify:completion:)`
    /// and `flushDataWith(delay:completion:)`. When `nil`, both methods preserve the historical
    /// `.noInternetConnection` response so pre-existing callers are unaffected.
    var stubbedResult: FlushResult?

    func flushDataWith(delay: Double, completion: ((FlushResult) -> Void)?) {
        completion?(stubbedResult ?? .noInternetConnection)
    }

    func flushData(isFromIdentify: Bool, completion: ((FlushResult) -> Void)?) {
        completion?(stubbedResult ?? .noInternetConnection)
    }

    var flushingMode: FlushingMode = .manual

    func applicationDidBecomeActive() {}

    func applicationDidEnterBackground() {}

    func hasPendingData() -> Bool { return false }
}
