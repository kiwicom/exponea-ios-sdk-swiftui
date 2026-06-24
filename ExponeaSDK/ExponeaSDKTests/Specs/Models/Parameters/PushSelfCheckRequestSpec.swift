//
//  PushSelfCheckRequestSpec.swift
//  ExponeaSDKTests
//
//  Created on 07/05/2026.
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK
@testable import ExponeaSDKShared

class PushSelfCheckRequestSpec: QuickSpec {
    override func spec() {
        describe("PushSelfCheckRequest parameters") {
            context("when constructed without an applicationID (backwards-compat path)") {
                let request = PushSelfCheckRequest(pushToken: "token-abc")

                it("emits platform=ios") {
                    expect(request.parameters["platform"]).to(equal(JSONValue.string("ios")))
                }

                it("emits push_notification_id with the supplied token") {
                    expect(request.parameters["push_notification_id"]).to(equal(JSONValue.string("token-abc")))
                }

                it("omits application_id so legacy callers keep their original payload shape") {
                    expect(request.parameters["application_id"]).to(beNil())
                }
            }

            context("when constructed with an explicit applicationID") {
                let request = PushSelfCheckRequest(
                    pushToken: "token-xyz",
                    applicationID: "com.example.app"
                )

                it("forwards application_id verbatim for multi-app routing") {
                    expect(request.parameters["application_id"]).to(equal(JSONValue.string("com.example.app")))
                }

                it("still emits platform and push_notification_id") {
                    expect(request.parameters["platform"]).to(equal(JSONValue.string("ios")))
                    expect(request.parameters["push_notification_id"]).to(equal(JSONValue.string("token-xyz")))
                }
            }

            context("when constructed with the default sentinel applicationID") {
                // Configuration always populates `applicationID`, falling back to
                // `Constants.General.applicationID` when the host app does not override it.
                // Sending the sentinel verbatim matches the AppInboxRequest contract and
                // lets the backend's backwards-compat path treat it as "no explicit app".
                let request = PushSelfCheckRequest(
                    pushToken: "token-default",
                    applicationID: Constants.General.applicationID
                )

                it("forwards the default sentinel without rewriting it to nil") {
                    expect(request.parameters["application_id"])
                        .to(equal(JSONValue.string(Constants.General.applicationID)))
                }
            }
        }
    }
}
