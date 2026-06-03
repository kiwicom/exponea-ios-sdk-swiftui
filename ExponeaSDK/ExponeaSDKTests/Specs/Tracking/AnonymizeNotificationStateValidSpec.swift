//
//  AnonymizeNotificationStateValidSpec.swift
//  ExponeaSDKTests
//
//  Verifies that `notification_state` events emitted from the anonymize()
//  re-registration path carry `valid == authorized` regardless of
//  `requirePushAuthorization`. The previous expression
//  `isValid: !requirePushAuthorization || authorized` incorrectly reported
//  `valid=true` when `requirePushAuthorization=false` even if the user had
//  denied notification permission.
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class AnonymizeNotificationStateValidSpec: QuickSpec {
    override func spec() {
        describe("anonymize() notification_state `valid` flag") {

            struct Case {
                let requirePushAuthorization: Bool
                let authorizationStatus: UNAuthorizationStatus
                let expectedValid: Bool
                var description: String {
                    "requirePushAuthorization=\(requirePushAuthorization), status=\(authorizationStatus), expectedValid=\(expectedValid)"
                }
            }

            // The matrix: after the fix, `valid` must equal `authorized` in all four
            // combinations. Before the fix, the last case (`requirePushAuthorization=false`
            // + denied) erroneously produced `valid=true`.
            let cases: [Case] = [
                Case(requirePushAuthorization: true, authorizationStatus: .authorized, expectedValid: true),
                Case(requirePushAuthorization: true, authorizationStatus: .denied, expectedValid: false),
                Case(requirePushAuthorization: false, authorizationStatus: .authorized, expectedValid: true),
                Case(requirePushAuthorization: false, authorizationStatus: .denied, expectedValid: false)
            ]

            afterEach {
                UNAuthorizationStatusProvider.current = MockUNAuthorizationStatusProviding(
                    status: .authorized
                )
            }

            func findAnonymizeNotificationStateAuthorized(
                events: [TrackEventProxy],
                newIntegrationId: String
            ) -> Bool? {
                // The anonymize() re-registration track is the `notification_state` event
                // written against the NEW project after the projects have been switched.
                // The `DatabaseManager` flattens `.pushNotificationToken(token, authorized)`
                // into two KeyValueItems: `push_notification_token` and `valid`. Read the
                // stored `valid` bool from the event's properties dict.
                let candidate = events.first { event in
                    event.eventType == Constants.EventTypes.notificationState &&
                    event.integrationId == newIntegrationId
                }
                guard let props = candidate?.dataTypes.properties,
                      let jsonConvertible = props["valid"] ?? nil,
                      case .bool(let value) = jsonConvertible.jsonValue else {
                    return nil
                }
                return value
            }

            for testCase in cases {
                it("tracks valid=\(testCase.expectedValid) for \(testCase.description)") {
                    let database = try! DatabaseManager()
                    try! database.clear()

                    IntegrationManager.shared.isStopped = false
                    UNAuthorizationStatusProvider.current = MockUNAuthorizationStatusProviding(
                        status: testCase.authorizationStatus
                    )

                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.userDefaults.set(
                        "device-id",
                        forKey: Constants.General.telemetryInstallId
                    )
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(
                            projectToken: "mock-token",
                            authorization: .token("mock-token")
                        ),
                        pushNotificationTracking: .enabled(
                            appGroup: "mock-group",
                            delegate: nil,
                            requirePushAuthorization: testCase.requirePushAuthorization,
                            tokenTrackFrequency: .onTokenChange
                        ),
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    Exponea.shared.trackPushToken("token")

                    Exponea.shared.anonymize(
                        exponeaIntegrationType: ExponeaProject(
                            projectToken: "other-mock-token",
                            authorization: .token("other-mock-token")
                        ),
                        exponeaProjectMapping: nil
                    )

                    let events = try! database.fetchTrackEvent()
                    let authorized = findAnonymizeNotificationStateAuthorized(
                        events: events,
                        newIntegrationId: "other-mock-token"
                    )
                    expect(authorized).toNot(
                        beNil(),
                        description: "No post-anonymize notification_state event found for new project"
                    )
                    expect(authorized).to(
                        equal(testCase.expectedValid),
                        description: "Expected valid=\(testCase.expectedValid) for \(testCase.description)"
                    )
                }
            }
        }
    }
}
