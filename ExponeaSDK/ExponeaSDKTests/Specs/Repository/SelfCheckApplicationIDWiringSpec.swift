//
//  SelfCheckApplicationIDWiringSpec.swift
//  ExponeaSDKTests
//
//  Created on 14/05/2026.
//  Copyright © 2026 Exponea. All rights reserved.
//

import Quick
import Nimble

@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class SelfCheckApplicationIDWiringSpec: QuickSpec {

    /// Parses the JSON body from a prepared URLRequest.
    private static func parseBody(from request: URLRequest) -> [String: Any]? {
        guard let data = request.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    override func spec() {
        describe("pushSelfCheck request body wiring") {

            context("with a custom applicationID") {
                it("should include application_id in the request body") {
                    let config = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-project",
                            authorization: .token("test-token"),
                            baseUrl: "https://mock-base-url.com"
                        ),
                        applicationID: "com.test.myapp"
                    )
                    let repo = ServerRepository(configuration: config)
                    let router = repo.makeRouter(
                        for: .pushSelfCheck,
                        project: config.mainProject
                    )
                    let request = try! router.prepareRequest(
                        parameters: PushSelfCheckRequest(
                            pushToken: "test-push-token",
                            applicationID: repo.configuration.applicationID
                        ),
                        customerIds: ["registered": "test@test.com"]
                    )

                    let body = SelfCheckApplicationIDWiringSpec.parseBody(from: request)
                    expect(body).toNot(beNil())
                    expect(body?["application_id"] as? String).to(equal("com.test.myapp"))
                    expect(body?["platform"] as? String).to(equal("ios"))
                    expect(body?["push_notification_id"] as? String).to(equal("test-push-token"))
                }
            }

            context("with the default applicationID") {
                it("should include the default sentinel in the request body") {
                    let config = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-project",
                            authorization: .token("test-token"),
                            baseUrl: "https://mock-base-url.com"
                        )
                    )
                    let repo = ServerRepository(configuration: config)
                    let router = repo.makeRouter(
                        for: .pushSelfCheck,
                        project: config.mainProject
                    )
                    let request = try! router.prepareRequest(
                        parameters: PushSelfCheckRequest(
                            pushToken: "test-push-token",
                            applicationID: repo.configuration.applicationID
                        ),
                        customerIds: ["registered": "test@test.com"]
                    )

                    let body = SelfCheckApplicationIDWiringSpec.parseBody(from: request)
                    expect(body).toNot(beNil())
                    expect(body?["application_id"] as? String)
                        .to(equal(Constants.General.applicationID))
                }
            }

            context("verifies configuration.applicationID flows to the request") {
                it("should reflect the configuration value, not a hardcoded default") {
                    let customID = "com.example.multi-app"
                    let config = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-project",
                            authorization: .token("test-token"),
                            baseUrl: "https://mock-base-url.com"
                        ),
                        applicationID: customID
                    )
                    let repo = ServerRepository(configuration: config)

                    expect(repo.configuration.applicationID).to(equal(customID))
                    expect(repo.configuration.applicationID).toNot(
                        equal(Constants.General.applicationID)
                    )

                    let router = repo.makeRouter(
                        for: .pushSelfCheck,
                        project: config.mainProject
                    )
                    let request = try! router.prepareRequest(
                        parameters: PushSelfCheckRequest(
                            pushToken: "token",
                            applicationID: repo.configuration.applicationID
                        )
                    )

                    let body = SelfCheckApplicationIDWiringSpec.parseBody(from: request)
                    expect(body?["application_id"] as? String).to(equal(customID))
                }
            }

            context("customer_ids wiring") {
                it("should include customer_ids alongside application_id") {
                    let config = try! Configuration(
                        integrationConfig: Exponea.ProjectSettings(
                            projectToken: "test-project",
                            authorization: .token("test-token"),
                            baseUrl: "https://mock-base-url.com"
                        ),
                        applicationID: "com.test.app"
                    )
                    let repo = ServerRepository(configuration: config)
                    let router = repo.makeRouter(
                        for: .pushSelfCheck,
                        project: config.mainProject
                    )
                    let request = try! router.prepareRequest(
                        parameters: PushSelfCheckRequest(
                            pushToken: "token-123",
                            applicationID: repo.configuration.applicationID
                        ),
                        customerIds: ["registered": "user@example.com"]
                    )

                    let body = SelfCheckApplicationIDWiringSpec.parseBody(from: request)
                    expect(body).toNot(beNil())
                    let customerIds = body?["customer_ids"] as? [String: String]
                    expect(customerIds).to(equal(["registered": "user@example.com"]))
                    expect(body?["application_id"] as? String).to(equal("com.test.app"))
                }
            }

            context("stream mode") {
                it("should include application_id in the stream self-check request body") {
                    let config = try! Configuration(
                        integrationConfig: Exponea.StreamSettings(
                            streamId: "test-stream",
                            baseUrl: "https://mock-base-url.com"
                        ),
                        applicationID: "com.stream.app"
                    )
                    let repo = ServerRepository(configuration: config)
                    let router = repo.makeRouter(
                        for: .pushSelfCheck,
                        project: config.mainProject
                    )
                    let request = try! router.prepareRequest(
                        parameters: PushSelfCheckRequest(
                            pushToken: "stream-token",
                            applicationID: repo.configuration.applicationID
                        ),
                        customerIds: ["registered": "stream@test.com"]
                    )

                    let body = SelfCheckApplicationIDWiringSpec.parseBody(from: request)
                    expect(body).toNot(beNil())
                    expect(body?["application_id"] as? String).to(equal("com.stream.app"))
                    expect(body?["platform"] as? String).to(equal("ios"))

                    expect(request.url?.absoluteString)
                        .to(contain("streams/test-stream/send-self-check-notification"))
                }
            }
        }
    }
}
