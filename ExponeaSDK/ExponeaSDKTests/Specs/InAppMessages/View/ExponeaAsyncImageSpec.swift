import Foundation
import Nimble
import Quick
import SwiftUI
import UIKit

@testable import ExponeaSDK

/// Intercepts `URLSession.shared` requests and returns a tiny valid PNG immediately,
/// so the Loader test is deterministic and does not hit the network.
private final class ExponeaAsyncImageStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        let data = image.pngData() ?? Data()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ExponeaAsyncImageSpec: QuickSpec {
    override func spec() {
        beforeSuite {
            URLProtocol.registerClass(ExponeaAsyncImageStubURLProtocol.self)
        }
        afterSuite {
            URLProtocol.unregisterClass(ExponeaAsyncImageStubURLProtocol.self)
        }

        describe("ExponeaAsyncImage.Loader") {
            it("is deallocated after loading finishes, confirming there is no retain cycle") {
                // Regression test for the retain cycle caused by `.assign(to:on:)`
                // in the Combine pipeline (Loader -> cancellables -> subscription -> Loader).
                // The current implementation uses `[weak self]` in the sink instead.
                weak var weakLoader: ExponeaAsyncImage<SwiftUI.Image>.Loader?

                autoreleasepool {
                    let loader = ExponeaAsyncImage<SwiftUI.Image>.Loader(
                        URL(string: "https://example.com/image.png")
                    )
                    weakLoader = loader

                    expect(loader.uiImage).toEventuallyNot(beNil(), timeout: .seconds(5))
                }

                expect(weakLoader).toEventually(beNil(), timeout: .seconds(5))
            }
        }
    }
}
