//
//  RequestFactory304Spec.swift
//  ExponeaSDKTests
//
//  Copyright © 2026 Exponea. All rights reserved.
//

import Foundation
import Quick
import Nimble
@testable import ExponeaSDK
@testable import ExponeaSDKShared

final class RequestFactory304Spec: QuickSpec {
    override func spec() {
        var factory: RequestFactory!

        beforeEach {
            let project = ExponeaProject(
                baseUrl: "https://api.exponea.com",
                projectToken: "test-token",
                authorization: .none
            )
            factory = RequestFactory(
                exponeaIntegrationType: project,
                route: .personalizedInAppContentBlocks
            )
        }

        func make304Response(url: URL = URL(string: "https://api.exponea.com")!) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil)!
        }

        describe("process() — HTTP 304 handling") {
            it("invokes onNotModified on the main queue and does NOT call resultAction") {
                var notModifiedCalled = false
                var resultActionCalled = false

                waitUntil { done in
                    factory.process(
                        make304Response(),
                        data: nil,
                        error: nil,
                        resultAction: { _ in resultActionCalled = true },
                        onNotModified: {
                            notModifiedCalled = true
                            done()
                        }
                    )
                }

                expect(notModifiedCalled).to(beTrue())
                expect(resultActionCalled).to(beFalse())
            }

            it("falls back to resultAction(.success) when onNotModified is nil") {
                var successCalled = false

                waitUntil { done in
                    factory.process(
                        make304Response(),
                        data: Data(),
                        error: nil,
                        resultAction: { result in
                            if case .success = result { successCalled = true }
                            done()
                        },
                        onNotModified: nil
                    )
                }

                expect(successCalled).to(beTrue())
            }
        }

        describe("process() — ETag header extraction on 200") {
            it("calls onEtagHeader with the ETag value from response headers") {
                let url = URL(string: "https://api.exponea.com")!
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"etag-value-123\""]
                )!
                var capturedEtag: String?

                waitUntil { done in
                    factory.process(
                        response,
                        data: Data("{}".utf8),
                        error: nil,
                        resultAction: { _ in done() },
                        onEtagHeader: { capturedEtag = $0 }
                    )
                }

                expect(capturedEtag).to(equal("\"etag-value-123\""))
            }

            it("does not call onEtagHeader when ETag header is absent") {
                let url = URL(string: "https://api.exponea.com")!
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                var etagHeaderCalled = false

                waitUntil { done in
                    factory.process(
                        response,
                        data: Data("{}".utf8),
                        error: nil,
                        resultAction: { _ in done() },
                        onEtagHeader: { _ in etagHeaderCalled = true }
                    )
                }

                expect(etagHeaderCalled).to(beFalse())
            }
        }
    }
}
