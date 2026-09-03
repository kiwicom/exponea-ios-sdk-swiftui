//
//  TrackPushTokenSessionTrackingSpec.swift
//  ExponeaSDKTests
//
//  Verifies that manually calling `trackPushToken(_:)` only marks the
//  `.everyLaunch` once-per-process session as satisfied when a token was
//  actually sent. `trackNotificationState` no-ops on a nil token (logs an error;
//  the existing push token is not deleted) without throwing, so the session
//  flag must not be set on that path — otherwise a deprecated nil-token manual call
//  would silently suppress the legitimate automatic `.everyLaunch` track
//  for the remainder of the process.
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class TrackPushTokenSessionTrackingSpec: QuickSpec {
    override func spec() {
        describe("trackPushToken(_:) session tracking") {
            var exponea: ExponeaInternal!
            var notificationsManagerSpy: MockPushNotificationManager!

            beforeEach {
                UNAuthorizationStatusProvider.current = MockUNAuthorizationStatusProviding(
                    status: .authorized
                )
                IntegrationManager.shared.isStopped = false
                let database = try! DatabaseManager()
                try! database.clear()

                exponea = ExponeaInternal()
                Exponea.shared = exponea
                Exponea.shared.configure(
                    Exponea.ProjectSettings(
                        projectToken: "mock-token",
                        authorization: .token("mock-token")
                    ),
                    pushNotificationTracking: .enabled(
                        appGroup: "mock-group",
                        requirePushAuthorization: false,
                        tokenTrackFrequency: .everyLaunch
                    ),
                    flushingSetup: Exponea.FlushingSetup(mode: .manual)
                )

                // Replace the real PushNotificationManager with a spy so the
                // interaction with `markEveryLaunchSessionTracked()` can be
                // asserted directly, independent of the manager's own
                // once-per-process bookkeeping (covered separately by
                // PushNotificationManagerProjectSpec / PushNotificationManagerStreamSpec).
                notificationsManagerSpy = MockPushNotificationManager()
                exponea.notificationsManager = notificationsManagerSpy
            }

            afterEach {
                UNAuthorizationStatusProvider.current = MockUNAuthorizationStatusProviding(
                    status: .authorized
                )
                IntegrationManager.shared.isStopped = false
            }

            it("does not mark the everyLaunch session as tracked when the token is nil") {
                Exponea.shared.trackPushToken(nil as String?)

                expect(notificationsManagerSpy.markEveryLaunchSessionTrackedCallCount).to(equal(0))
            }

            it("marks the everyLaunch session as tracked when a valid token is sent") {
                Exponea.shared.trackPushToken("valid-token")

                expect(notificationsManagerSpy.markEveryLaunchSessionTrackedCallCount).to(equal(1))
            }

            it("marks the everyLaunch session as tracked only once per valid manual track") {
                Exponea.shared.trackPushToken(nil as String?)
                Exponea.shared.trackPushToken("valid-token")
                Exponea.shared.trackPushToken(nil as String?)

                expect(notificationsManagerSpy.markEveryLaunchSessionTrackedCallCount).to(equal(1))
            }

            it("does not mark the everyLaunch session as tracked when the SDK is stopped") {
                IntegrationManager.shared.isStopped = true

                Exponea.shared.trackPushToken("valid-token")

                expect(notificationsManagerSpy.markEveryLaunchSessionTrackedCallCount).to(equal(0))
            }
        }
    }
}

