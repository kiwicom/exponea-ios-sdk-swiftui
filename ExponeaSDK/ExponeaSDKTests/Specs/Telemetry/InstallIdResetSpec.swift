//
//  InstallIdResetSpec.swift
//  ExponeaSDKTests
//
//  Verifies that the telemetry install ID (used as device_id in notification_state and other events)
//  is cleared when stopIntegration() or clearLocalCustomerData(appGroup:) is called.
//
//  Anonymize behavior depends on Configuration.regenerateDeviceIdOnAnonymize:
//  - flag=false (default): install ID is preserved across anonymize (backward-compatible).
//  - flag=true: install ID is cleared so the next getInstallId() returns a NEW UUID (GDPR opt-in).
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class InstallIdResetSpec: QuickSpec {
    private static func restoreExponeaShared() {
        let exponea = ExponeaInternal()
        Exponea.shared = exponea
        exponea.configure(
            Exponea.ProjectSettings(projectToken: "cleanup-token", authorization: .token("cleanup")),
            pushNotificationTracking: .enabled(appGroup: "group.test.exponea.cleanup"),
            flushingSetup: Exponea.FlushingSetup(mode: .manual)
        )
        IntegrationManager.shared.isStopped = false
    }

    override func spec() {
        describe("Install ID (device_id) reset on stop and clear") {
            context("stopIntegration") {
                let appGroup = "group.test.exponea.installid.reset"

                beforeEach {
                    IntegrationManager.shared.isStopped = false
                    TelemetryUtility.clearInstallIdFromAllStores(appGroup: appGroup)
                    UserDefaults(suiteName: appGroup)?.removeObject(forKey: Constants.General.lastKnownConfiguration)
                }

                afterEach {
                    InstallIdResetSpec.restoreExponeaShared()
                }

                it("clears install ID from app group UserDefaults so next getInstallId returns a new value") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(projectToken: "test-token", authorization: .token("test")),
                        pushNotificationTracking: .enabled(appGroup: appGroup),
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    let defaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let installIdBeforeStop = TelemetryUtility.getInstallId(userDefaults: defaults)
                    expect(installIdBeforeStop).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeStop)).notTo(beNil())

                    waitUntil(timeout: .seconds(5)) { done in
                        Exponea.shared.stopIntegration(completion: {
                            done()
                        })
                    }

                    let installIdAfterStop = TelemetryUtility.getInstallId(userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup))
                    expect(installIdAfterStop).notTo(equal(installIdBeforeStop))
                    expect(UUID(uuidString: installIdAfterStop)).notTo(beNil())
                }
            }

            context("clearLocalCustomerData") {
                let appGroup = "group.test.exponea.clear.installid"

                beforeEach {
                    Exponea.shared = ExponeaInternal()
                    TelemetryUtility.clearInstallIdFromAllStores(appGroup: appGroup)
                    UserDefaults(suiteName: appGroup)?.removeObject(forKey: Constants.General.lastKnownConfiguration)
                }

                afterEach {
                    InstallIdResetSpec.restoreExponeaShared()
                }

                it("clears install ID from app group UserDefaults so next getInstallId returns a new value") {
                    let configuration = try! Configuration(
                        projectToken: "test-token",
                        authorization: .none,
                        baseUrl: Constants.Repository.baseUrl,
                        appGroup: appGroup
                    )
                    configuration.saveToUserDefaults()
                    expect(Configuration.loadFromUserDefaults(appGroup: appGroup)).notTo(beNil())

                    let appGroupDefaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    appGroupDefaults.set("old-install-id-in-appgroup", forKey: Constants.General.telemetryInstallId)

                    Exponea.shared.clearLocalCustomerData(appGroup: appGroup)

                    let installIdAfterClear = TelemetryUtility.getInstallId(userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup))
                    expect(installIdAfterClear).notTo(equal("old-install-id-in-appgroup"))
                    expect(UUID(uuidString: installIdAfterClear)).notTo(beNil())
                }

                it("clears install ID from UserDefaults.standard when it was stored there (fallback suite)") {
                    let configuration = try! Configuration(
                        projectToken: "test-token",
                        authorization: .none,
                        baseUrl: Constants.Repository.baseUrl,
                        appGroup: appGroup
                    )
                    configuration.saveToUserDefaults()
                    expect(Configuration.loadFromUserDefaults(appGroup: appGroup)).notTo(beNil())

                    UserDefaults.standard.set("old-install-id-in-standard", forKey: Constants.General.telemetryInstallId)

                    Exponea.shared.clearLocalCustomerData(appGroup: appGroup)

                    let installIdAfterClear = TelemetryUtility.getInstallId(userDefaults: UserDefaults.standard)
                    expect(installIdAfterClear).notTo(equal("old-install-id-in-standard"))
                    expect(UUID(uuidString: installIdAfterClear)).notTo(beNil())
                }
            }

            context("anonymize with regenerateDeviceIdOnAnonymize = false (default)") {
                let appGroup = "group.test.exponea.anonymize.installid.default"

                beforeEach {
                    IntegrationManager.shared.isStopped = false
                    TelemetryUtility.clearInstallIdFromAllStores(appGroup: appGroup)
                    UserDefaults(suiteName: appGroup)?.removeObject(forKey: Constants.General.lastKnownConfiguration)
                }

                afterEach {
                    InstallIdResetSpec.restoreExponeaShared()
                }

                it("preserves install ID across anonymize when the flag is left at its default false value") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(projectToken: "test-token", authorization: .token("test")),
                        pushNotificationTracking: .enabled(appGroup: appGroup),
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    let defaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let installIdBeforeAnonymize = TelemetryUtility.getInstallId(userDefaults: defaults)
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = TelemetryUtility.getInstallId(
                        userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    )
                    expect(installIdAfterAnonymize).to(equal(installIdBeforeAnonymize))
                }

                it("preserves install ID across anonymize when the flag is explicitly set to false") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-token",
                            authorization: .token("test")
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: false
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    let defaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let installIdBeforeAnonymize = TelemetryUtility.getInstallId(userDefaults: defaults)
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = TelemetryUtility.getInstallId(
                        userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    )
                    expect(installIdAfterAnonymize).to(equal(installIdBeforeAnonymize))
                }

                // No-regression check for the Sentry surface when the flag is left at its
                // default false value. Verifies the closure-based installIdProvider keeps returning the same value
                // across an anonymize() call (i.e. the regeneration gate did not fire).
                it("preserves SentryTelemetryUpload installId across anonymize when the flag is false") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-token",
                            authorization: .token("test")
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: false
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    let userDefaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let sentryUpload = SentryTelemetryUpload(
                        installIdProvider: { TelemetryUtility.getInstallId(userDefaults: userDefaults) },
                        configGetter: { Exponea.shared.configuration }
                    )

                    let installIdBeforeAnonymize = sentryUpload.installId
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = sentryUpload.installId
                    expect(installIdAfterAnonymize).to(equal(installIdBeforeAnonymize))
                }
            }

            context("anonymize with regenerateDeviceIdOnAnonymize = true") {
                let appGroup = "group.test.exponea.anonymize.installid.regenerate"

                beforeEach {
                    IntegrationManager.shared.isStopped = false
                    TelemetryUtility.clearInstallIdFromAllStores(appGroup: appGroup)
                    UserDefaults(suiteName: appGroup)?.removeObject(forKey: Constants.General.lastKnownConfiguration)
                }

                afterEach {
                    InstallIdResetSpec.restoreExponeaShared()
                }

                it("regenerates install ID after anonymize when the flag is true (GDPR opt-in)") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-token",
                            authorization: .token("test")
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: true
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    let defaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let installIdBeforeAnonymize = TelemetryUtility.getInstallId(userDefaults: defaults)
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = TelemetryUtility.getInstallId(
                        userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    )
                    expect(installIdAfterAnonymize).notTo(equal(installIdBeforeAnonymize))
                    expect(UUID(uuidString: installIdAfterAnonymize)).notTo(beNil())
                }

                it("regenerates install ID from UserDefaults.standard fallback when the flag is true") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-token",
                            authorization: .token("test")
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: true
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    UserDefaults.standard.set(
                        "old-install-id-in-standard",
                        forKey: Constants.General.telemetryInstallId
                    )

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = TelemetryUtility.getInstallId(
                        userDefaults: UserDefaults.standard
                    )
                    expect(installIdAfterAnonymize).notTo(equal("old-install-id-in-standard"))
                    expect(UUID(uuidString: installIdAfterAnonymize)).notTo(beNil())
                }

                // Verifies the Sentry telemetry uploader picks up the new install ID
                // after anonymize(), without requiring the upload (or TelemetryManager) to be recreated.
                // Mirrors the production wiring in TelemetryManager.init (closure-based installIdProvider).
                it("rotates SentryTelemetryUpload installId after anonymize when the flag is true") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-token",
                            authorization: .token("test")
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: true
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    let userDefaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let sentryUpload = SentryTelemetryUpload(
                        installIdProvider: { TelemetryUtility.getInstallId(userDefaults: userDefaults) },
                        configGetter: { Exponea.shared.configuration }
                    )

                    let installIdBeforeAnonymize = sentryUpload.installId
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = sentryUpload.installId
                    expect(installIdAfterAnonymize).notTo(equal(installIdBeforeAnonymize))
                    expect(UUID(uuidString: installIdAfterAnonymize)).notTo(beNil())
                }

                it("regenerates install ID after anonymize in Stream mode when the flag is true") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    let configuration = try! Configuration(
                        integrationConfig: Exponea.StreamSettings(
                            streamId: "test-stream-id",
                            baseUrl: "https://api.exponea.com"
                        ),
                        appGroup: appGroup,
                        regenerateDeviceIdOnAnonymize: true
                    )
                    Exponea.shared.configure(with: configuration)
                    Exponea.shared.flushingMode = .manual

                    let defaults = TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    let installIdBeforeAnonymize = TelemetryUtility.getInstallId(userDefaults: defaults)
                    expect(installIdBeforeAnonymize).notTo(beEmpty())
                    expect(UUID(uuidString: installIdBeforeAnonymize)).notTo(beNil())

                    Exponea.shared.anonymize()

                    let installIdAfterAnonymize = TelemetryUtility.getInstallId(
                        userDefaults: TelemetryUtility.getUserDefaults(appGroup: appGroup)
                    )
                    expect(installIdAfterAnonymize).notTo(equal(installIdBeforeAnonymize))
                    expect(UUID(uuidString: installIdAfterAnonymize)).notTo(beNil())
                }
            }
        }
    }
}
