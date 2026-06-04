//
//  AnonymizeWithIntegrationAndCompletionSpec.swift
//  ExponeaSDKTests
//
//  Created by Bloomreach on 03/06/2026.
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation
import Nimble
import Quick

@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class AnonymizeWithIntegrationAndCompletionSpec: QuickSpec {

    override func spec() {
        describe("anonymize(exponeaIntegrationType:exponeaProjectMapping:completion:)") {

            beforeEach {
                IntegrationManager.shared.isStopped = false
                let database = try! DatabaseManager()
                try! database.clear()
            }

            afterEach {
                NetworkStubbing.unstubNetwork()
                IntegrationManager.shared.isStopped = false
            }

            context("Project mode switch") {

                it("invokes completion on the main thread after project switch") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(
                            projectToken: "mock-token",
                            authorization: .token("mock-token")
                        ),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    waitUntil(timeout: .seconds(5)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaProject(
                                projectToken: "other-mock-token",
                                authorization: .token("other-mock-token")
                            ),
                            exponeaProjectMapping: nil,
                            completion: {
                                expect(Thread.isMainThread).to(beTrue())
                                expect(
                                    (Exponea.shared.configuration?.integrationConfig as? Exponea.ProjectSettings)?.projectToken
                                ).to(equal("other-mock-token"))
                                done()
                            }
                        )
                    }
                }

                it("invokes completion exactly once") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(
                            projectToken: "mock-token",
                            authorization: .token("mock-token")
                        ),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    var callCount = 0
                    Exponea.shared.anonymize(
                        exponeaIntegrationType: ExponeaProject(
                            projectToken: "other-mock-token",
                            authorization: .token("other-mock-token")
                        ),
                        exponeaProjectMapping: nil,
                        completion: {
                            callCount += 1
                        }
                    )

                    expect(callCount).toEventually(equal(1), timeout: .seconds(3))
                    // Drain the main runloop so any erroneously-queued additional
                    // DispatchQueue.main.async invocations of completion would be observed.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    expect(callCount).to(equal(1))
                }

                it("invokes completion when a non-nil project mapping is supplied") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(
                            projectToken: "mock-token",
                            authorization: .token("mock-token")
                        ),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    waitUntil(timeout: .seconds(5)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaProject(
                                projectToken: "primary-mock-token",
                                authorization: .token("primary-mock-token")
                            ),
                            exponeaProjectMapping: [
                                .identifyCustomer: [
                                    ExponeaProject(
                                        projectToken: "secondary-mock-token",
                                        authorization: .token("secondary-mock-token")
                                    )
                                ]
                            ],
                            completion: {
                                done()
                            }
                        )
                    }
                }
            }

            context("Stream mode switch") {

                it("invokes completion on the main thread when no flush is required") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.StreamSettings(streamId: "mock-stream"),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    waitUntil(timeout: .seconds(5)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaIntegration(
                                streamId: "other-mock-stream"
                            ),
                            exponeaProjectMapping: nil,
                            completion: {
                                expect(Thread.isMainThread).to(beTrue())
                                expect(
                                    (Exponea.shared.configuration?.integrationConfig as? Exponea.StreamSettings)?.streamId
                                ).to(equal("other-mock-stream"))
                                done()
                            }
                        )
                    }
                }

                it("invokes completion on the main thread after the pre-anonymize flush") {
                    NetworkStubbing.stubNetwork(
                        forIntegrationType: .stream(streamId: "mock-stream"),
                        withStatusCode: 200,
                        withDelay: TimeInterval(0.1)
                    )

                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.StreamSettings(streamId: "mock-stream"),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )
                    Exponea.shared.setSdkAuthToken(JwtAuthManagerSpec.createValidJwt())
                    expect(Exponea.shared.jwtAuthManager?.currentTokenSnapshot)
                        .toEventuallyNot(beNil(), timeout: .seconds(1))

                    waitUntil(timeout: .seconds(10)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaIntegration(
                                streamId: "other-mock-stream"
                            ),
                            exponeaProjectMapping: nil,
                            completion: {
                                expect(Thread.isMainThread).to(beTrue())
                                done()
                            }
                        )
                    }
                }
            }

            context("When integration manager stops mid-anonymize") {

                it("invokes completion on the main thread via the in-flight isStopped guard") {
                    NetworkStubbing.stubNetwork(
                        forIntegrationType: .stream(streamId: "mock-stream"),
                        withStatusCode: 200,
                        withDelay: TimeInterval(0.5)
                    )

                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.StreamSettings(streamId: "mock-stream"),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )
                    Exponea.shared.setSdkAuthToken(JwtAuthManagerSpec.createValidJwt())
                    expect(Exponea.shared.jwtAuthManager?.currentTokenSnapshot)
                        .toEventuallyNot(beNil(), timeout: .seconds(1))

                    waitUntil(timeout: .seconds(10)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaIntegration(
                                streamId: "other-mock-stream"
                            ),
                            exponeaProjectMapping: nil,
                            completion: {
                                expect(Thread.isMainThread).to(beTrue())
                                done()
                            }
                        )
                        // Toggle isStopped while the pre-anonymize flush is still in flight,
                        // exercising the guard inside performAnonymize's completeAnonymize block.
                        IntegrationManager.shared.isStopped = true
                    }
                }
            }

            context("Default exponeaProjectMapping argument") {

                it("invokes the integration switch without explicit project mapping") {
                    let exponea = ExponeaInternal()
                    Exponea.shared = exponea
                    Exponea.shared.configure(
                        Exponea.ProjectSettings(
                            projectToken: "mock-token",
                            authorization: .token("mock-token")
                        ),
                        pushNotificationTracking: .disabled,
                        flushingSetup: Exponea.FlushingSetup(mode: .manual)
                    )

                    waitUntil(timeout: .seconds(5)) { done in
                        Exponea.shared.anonymize(
                            exponeaIntegrationType: ExponeaProject(
                                projectToken: "other-mock-token",
                                authorization: .token("other-mock-token")
                            ),
                            completion: {
                                done()
                            }
                        )
                    }
                }
            }
        }
    }
}
