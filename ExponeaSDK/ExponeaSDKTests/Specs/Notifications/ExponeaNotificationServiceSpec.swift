//
//  ExponeaNotificationServiceSpec.swift
//  ExponeaSDKTests
//
//  Created by Panaxeo on 31/10/2019.
//  Copyright © 2019 Exponea. All rights reserved.
//

import Quick
import Nimble
import UserNotifications

@testable import ExponeaSDK
@testable import ExponeaSDKNotifications
@testable import ExponeaSDKShared

/// Synchronous stub backing `DeliveryAuthorizationProvider.current` so the
/// NSE-end-to-end specs can pin the resolver's input without invoking
/// `UNUserNotificationCenter.current()` (not safe under XCTest).
private struct StubDeliveryAuthorizationProvider: DeliveryAuthorizationProviding {
    let snapshot: DeliveryAuthorizationSnapshot?

    func currentDeliveryAuthorization(
        completion: @escaping (DeliveryAuthorizationSnapshot?) -> Void
    ) {
        completion(snapshot)
    }
}

final class ExponeaNotificationServiceSpec: QuickSpec {

    private let testConfigurations: [Configuration] = [
        try! Configuration(
            projectToken: "mock-project-token",
            projectMapping: nil,
            authorization: .token("mock-token"),
            baseUrl: nil,
            appGroup: "mock-app-group",
            defaultProperties: nil
        ),
        try! Configuration(
            integrationConfig: Exponea.ProjectSettings(
                projectToken: "mock-project-token",
                authorization: .token("mock-token"),
                baseUrl: nil,
                projectMapping: nil
            ),
            appGroup: "mock-app-group",
            defaultProperties: nil
        ),
        try! Configuration(
            integrationConfig: Exponea.StreamSettings(
                streamId: "mock-project-token",
                baseUrl: nil
            ),
            appGroup: "mock-app-group",
            defaultProperties: nil
        )
    ]
    
    private func mock_notification_request(userInfo: [AnyHashable: Any]?) -> UNNotificationRequest {
        let content = UNNotificationContent()
        content.setValue(userInfo, forKey: "userInfo")
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        return request
    }

    private func getRecordedNotifications() -> [Data] {
        if let userDefaults = UserDefaults(suiteName: "mock-app-group"),
           let delivered = userDefaults.array(forKey: ExponeaSDK.Constants.General.deliveredPushUserDefaultsKey)
           as? [Data] {
            return delivered
        }
        return []
    }

    private func getRecordedNotificationEvents() -> [Data] {
        if let userDefaults = UserDefaults(suiteName: "mock-app-group"),
           let delivered = userDefaults.array(forKey: ExponeaSDK.Constants.General.deliveredPushEventUserDefaultsKey)
           as? [Data] {
            return delivered
        }
        return []
    }

    override func spec() {
        beforeEach {
            IntegrationManager.shared.isStopped = false
            UserDefaults.standard.removePersistentDomain(forName: "mock-app-group")
        }
        describe("saving notifications for later") {
            it("should record notification into user defaults") {
                let service = ExponeaNotificationService(appGroup: "mock-app-group")
                service.telemetry = nil
                service.saveNotificationForLaterTracking(
                    notification: NotificationData( attributes: ["campaign_name": .string("mock campaign name")])
                )
                let delivered = self.getRecordedNotifications()
                expect(delivered.count).to(equal(1))
                let savedNotificationData = NotificationData.deserialize(from: delivered[0])
                expect(savedNotificationData?.campaignName).to(equal("mock campaign name"))
            }

            context("should record notification event into user defaults") {
                for configuration in testConfigurations {
                    it(configuration.integrationConfig.type.rawValue) {
                        let service = ExponeaNotificationService(appGroup: "mock-app-group")
                        service.telemetry = nil
                        let notification = NotificationData( attributes: ["campaign_name": .string("mock campaign name")])
                        let events = DeliveredNotificationTracker.generateTrackingObjects(
                            configuration: configuration,
                            customerIds: ["cookie": "12345"],
                            notification: notification
                        )
                        service.saveNotificationEventsForLaterTracking(events)
                        let delivered = self.getRecordedNotifications()
                        expect(delivered).to(beEmpty())
                        let deliveredEvents = self.getRecordedNotificationEvents()
                        expect(deliveredEvents.count).to(equal(1))
                    }
                }
            }

            it("should record notification without tracking info into user defaults") {
                let service = ExponeaNotificationService(appGroup: "mock-app-group")
                service.telemetry = nil
                service.saveNotificationForLaterTracking(
                    notification: NotificationData()
                )
                let delivered = self.getRecordedNotifications()
                expect(delivered.count).to(equal(1))
            }

            it("should record multiple notifications into user defaults") {
                let service = ExponeaNotificationService(appGroup: "mock-app-group")
                service.telemetry = nil
                service.saveNotificationForLaterTracking(
                    notification: NotificationData( attributes: ["campaign_name": .string("mock campaign name")])
                )
                service.saveNotificationForLaterTracking(
                    notification: NotificationData( attributes: ["campaign_name": .string("second mock campaign name")])
                )
                service.saveNotificationForLaterTracking(
                    notification: NotificationData( attributes: ["campaign_name": .string("third mock campaign name")])
                )
                let delivered = self.getRecordedNotifications()
                expect(delivered.count).to(equal(3))
                expect(NotificationData.deserialize(from: delivered[0])?.campaignName).to(
                    equal("mock campaign name")
                )
                expect(NotificationData.deserialize(from: delivered[1])?.campaignName).to(
                    equal("second mock campaign name")
                )
                expect(NotificationData.deserialize(from: delivered[2])?.campaignName).to(
                    equal("third mock campaign name")
                )
            }

            context("should record multiple notification events into user defaults") {
                for configuration in testConfigurations {
                    it(configuration.integrationConfig.type.rawValue) {
                        let service = ExponeaNotificationService(appGroup: "mock-app-group")
                        service.telemetry = nil
                        let customerIds = ["cookie": "1234"]
                        service.saveNotificationEventsForLaterTracking(DeliveredNotificationTracker.generateTrackingObjects(
                            configuration: configuration,
                            customerIds: customerIds,
                            notification: NotificationData( attributes: ["campaign_name": .string("first mock campaign name")])
                        ))
                        service.saveNotificationEventsForLaterTracking(DeliveredNotificationTracker.generateTrackingObjects(
                            configuration: configuration,
                            customerIds: customerIds,
                            notification: NotificationData( attributes: ["campaign_name": .string("second mock campaign name")])
                        ))
                        service.saveNotificationEventsForLaterTracking(DeliveredNotificationTracker.generateTrackingObjects(
                            configuration: configuration,
                            customerIds: customerIds,
                            notification: NotificationData( attributes: ["campaign_name": .string("third mock campaign name")])
                        ))
                        let deliveredEvents = self.getRecordedNotificationEvents()
                        expect(deliveredEvents.count).to(equal(3))
                        let event1 = EventTrackingObject.deserialize(from: deliveredEvents[0])
                        expect(event1?.customerIds["cookie"]).to(equal("1234"))
                        let campaignName1: String = event1?.dataTypes.properties["campaign_name"]?.unsafelyUnwrapped.jsonValue.rawValue as! String
                        expect(campaignName1).to(equal("first mock campaign name"))
                        let event2 = EventTrackingObject.deserialize(from: deliveredEvents[1])
                        expect(event2?.customerIds["cookie"]).to(equal("1234"))
                        let campaignName2: String = event2?.dataTypes.properties["campaign_name"]?.unsafelyUnwrapped.jsonValue.rawValue as! String
                        expect(campaignName2).to(equal("second mock campaign name"))
                        let event3 = EventTrackingObject.deserialize(from: deliveredEvents[2])
                        expect(event3?.customerIds["cookie"]).to(equal("1234"))
                        let campaignName3: String = event3?.dataTypes.properties["campaign_name"]?.unsafelyUnwrapped.jsonValue.rawValue as! String
                        expect(campaignName3).to(equal("third mock campaign name"))
                    }
                }
            }
        }

        describe("processing") {
            let userInfo = try! JSONSerialization.jsonObject(
                with: PushNotificationsTestData().deliveredCustomActionsNotification.data(using: .utf8) ?? Data(), options: []
            ) as? [AnyHashable: Any]
            let request = mock_notification_request(userInfo: userInfo)

            it("should create content") {
                let service = ExponeaNotificationService(appGroup: "mock-app-group")
                service.telemetry = nil
                waitUntil(timeout: .seconds(5)) { done in
                    service.process(request: request) { content in
                        expect(content.title).to(equal("Test push notification title"))
                        expect(content.body).to(equal("test push notification message"))
                        done()
                    }
                }
            }

            it("should save notification for later when unable to track") {
                let service = ExponeaNotificationService(appGroup: "mock-app-group")
                service.telemetry = nil
                waitUntil(timeout: .seconds(5)) { done in
                    service.process(request: request) { _ in
                        // for missing SDK conf, only raw NotifPayload should be stored
                        let delivered = self.getRecordedNotifications()
                        expect(delivered.count).to(equal(1))
                        // for missing SDK conf, delivered events could not be created
                        let deliveredEvents = self.getRecordedNotificationEvents()
                        expect(deliveredEvents).to(beEmpty())
                        done()
                    }
                }
            }

            context("should not save notification events for later when tracking failed by network") {
                for configuration in testConfigurations {
                    it(configuration.integrationConfig.type.rawValue) {
                        configuration.saveToUserDefaults()
                        
                        guard let userDefaults = UserDefaults(suiteName: "mock-app-group"),
                            let data = try? JSONEncoder().encode(["uuid": ExponeaSDK.JSONValue.string("mock-uuid")]) else {
                            return
                        }
                        userDefaults.set(data, forKey: Constants.General.lastKnownCustomerIds)
                        let service = ExponeaNotificationService(appGroup: "mock-app-group")
                        service.telemetry = nil
                        waitUntil(timeout: .seconds(5)) { done in
                            service.process(request: request) { _ in
                                // for existing SDK conf, raw NotifPayloads are meaningless to be stored
                                expect(self.getRecordedNotifications()).to(beEmpty())
                                // for existing SDK conf, delivered events has to be created and stored
                                let deliveredEvents = self.getRecordedNotificationEvents()
                                expect(deliveredEvents.count).to(equal(1))
                                done()
                            }
                        }
                    }
                }
            }

            // Pins the wire-up between
            // `ExponeaNotificationService.trackDeliveredNotification` and
            // `DeliveredNotificationStateResolver`. The NSE init's
            // production-backend install is a no-op under XCTest, so the
            // resolver's input is sourced entirely from the stub installed
            // in each example. Tracking is forced to fail (400 stub) so
            // the delivered event is persisted via
            // `saveNotificationEventsForLaterTracking`, which is the only
            // way to inspect the emitted payload from a unit test. A
            // deterministic 400 stub also isolates this context from
            // earlier tests in the same `describe` that leave 200-stubs
            // active for the same integration type.
            context("should propagate the resolved authorization state onto the recorded delivered event") {
                let configuration = self.testConfigurations[0]

                beforeEach {
                    NetworkStubbing.unstubNetwork()
                    NetworkStubbing.stubNetwork(
                        forIntegrationType: configuration.integrationConfig.type,
                        withStatusCode: 400
                    )
                }

                afterEach {
                    NetworkStubbing.unstubNetwork()
                }

                struct StateCase {
                    let description: String
                    let snapshot: DeliveryAuthorizationSnapshot?
                    let expectedState: String
                }

                let cases: [StateCase] = [
                    StateCase(
                        description: "authorized + alerts enabled => shown",
                        snapshot: DeliveryAuthorizationSnapshot(
                            authorizationStatus: .authorized,
                            alertSetting: .enabled
                        ),
                        expectedState: DeliveredNotificationStateResolver.shownValue
                    ),
                    StateCase(
                        description: "denied + alerts disabled => not_shown",
                        snapshot: DeliveryAuthorizationSnapshot(
                            authorizationStatus: .denied,
                            alertSetting: .disabled
                        ),
                        expectedState: DeliveredNotificationStateResolver.notShownValue
                    ),
                    StateCase(
                        description: "authorized but alerts disabled => not_shown",
                        snapshot: DeliveryAuthorizationSnapshot(
                            authorizationStatus: .authorized,
                            alertSetting: .disabled
                        ),
                        expectedState: DeliveredNotificationStateResolver.notShownValue
                    ),
                    StateCase(
                        description: "nil snapshot => legacy shown fallback",
                        snapshot: nil,
                        expectedState: DeliveredNotificationStateResolver.shownValue
                    )
                ]

                for testCase in cases {
                    it(testCase.description) {
                        configuration.saveToUserDefaults()

                        guard let userDefaults = UserDefaults(suiteName: "mock-app-group"),
                              let data = try? JSONEncoder().encode(
                                  ["uuid": ExponeaSDK.JSONValue.string("mock-uuid")]
                              ) else {
                            fail("unable to seed customer ids")
                            return
                        }
                        userDefaults.set(data, forKey: Constants.General.lastKnownCustomerIds)

                        let originalProvider = DeliveryAuthorizationProvider.current
                        DeliveryAuthorizationProvider.current =
                            StubDeliveryAuthorizationProvider(snapshot: testCase.snapshot)
                        defer { DeliveryAuthorizationProvider.current = originalProvider }

                        let service = ExponeaNotificationService(appGroup: "mock-app-group")
                        service.telemetry = nil
                        waitUntil(timeout: .seconds(5)) { done in
                            service.process(request: request) { _ in
                                let deliveredEvents = self.getRecordedNotificationEvents()
                                expect(deliveredEvents.count).to(equal(1))
                                let event = EventTrackingObject.deserialize(from: deliveredEvents[0])
                                let state = event?.dataTypes.properties["state"]?
                                    .unsafelyUnwrapped.jsonValue.rawValue as? String
                                expect(state).to(equal(testCase.expectedState))
                                done()
                            }
                        }
                    }
                }
            }

            context("should not save notification for later when tracking succeeds") {
                for configuration in testConfigurations {
                    it(configuration.integrationConfig.type.rawValue) {
                        configuration.saveToUserDefaults()
                        
                        guard let userDefaults = UserDefaults(suiteName: "mock-app-group"),
                            let data = try? JSONEncoder().encode(["uuid": ExponeaSDK.JSONValue.string("mock-uuid")]) else {
                            return
                        }
                        userDefaults.set(data, forKey: Constants.General.lastKnownCustomerIds)
                        NetworkStubbing.stubNetwork(forIntegrationType: configuration.integrationConfig.type, withStatusCode: 200)
                        let service = ExponeaNotificationService(appGroup: "mock-app-group")
                        service.telemetry = nil
                        waitUntil(timeout: .seconds(5)) { done in
                            service.process(request: request) { _ in
                                expect(self.getRecordedNotifications()).to(beEmpty())
                                expect(self.getRecordedNotificationEvents()).to(beEmpty())
                                done()
                            }
                        }
                    }
                }
            }
        }
    }
}
