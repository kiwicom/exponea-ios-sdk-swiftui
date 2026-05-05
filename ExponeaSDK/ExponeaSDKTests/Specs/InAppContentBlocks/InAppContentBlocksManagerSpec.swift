//
//  InAppContentBlocksManagerSpec.swift.swift
//  ExponeaSDKTests
//
//  Created by Ankmara on 22.06.2023.
//  Copyright © 2023 Exponea. All rights reserved.
//

import Foundation
import Quick
import Nimble
import Combine
import UIKit
import WebKit
import Mockingjay
@testable import ExponeaSDK

/// Test double that records every `loadHTMLString` call routed through it.
///
/// Used by the WebContent-process-termination recovery specs so we can assert
/// that the cell / calculator re-issued the cached HTML *into the supplied
/// `WKWebView` parameter* (i.e. self-at-runtime in production), without
/// spinning up the real WebKit IPC. Recording is synchronous; the super call
/// is forwarded so the spy stays a fully-functional `WKWebView` and any
/// `WKNavigationDelegate` wiring on the system under test continues to work.
fileprivate final class LoadHTMLStringSpyWebView: WKWebView {
    private(set) var loadedHtmlStrings: [String] = []
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHtmlStrings.append(string)
        return super.loadHTMLString(string, baseURL: baseURL)
    }
}

fileprivate class CustomCarouselCallback: DefaultContentBlockCarouselCallback {

    var notFoundCallback: EmptyBlock?
    var onMessageChangedCallback: EmptyBlock?

    var overrideDefaultBehavior: Bool = false
    var trackActions: Bool = true

    init() {}

    func onMessageShown(placeholderId: String, contentBlock: ExponeaSDK.InAppContentBlockResponse, index: Int, count: Int) {
        // space for custom implementation
    }
    
    func onMessagesChanged(count: Int, messages: [ExponeaSDK.InAppContentBlockResponse]) {
        // space for custom implementation
        onMessageChangedCallback?()
    }

    func onNoMessageFound(placeholderId: String) {
        // space for custom implementation
        notFoundCallback?()
    }

    func onError(placeholderId: String, contentBlock: ExponeaSDK.InAppContentBlockResponse?, errorMessage: String) {
        // space for custom implementation
    }

    func onCloseClicked(placeholderId: String, contentBlock: ExponeaSDK.InAppContentBlockResponse) {
        // space for custom implementation
    }

    func onActionClickedSafari(placeholderId: String, contentBlock: ExponeaSDK.InAppContentBlockResponse, action: ExponeaSDK.InAppContentBlockAction) {
        // space for custom implementation
    }

    func onHeightUpdate(placeholderId: String, height: CGFloat) {
        Exponea.logger.log(.verbose, message: "Placeholder \(placeholderId) got new height: \(height)")
    }
}

class InAppContentBlocksManagerSpec: QuickSpec {

    let configuration = try! Configuration(
        projectToken: "token",
        authorization: Authorization.none,
        baseUrl: "baseUrl"
    )

    override func spec() {
        var manager: InAppContentBlocksManagerType!
        var callback: CustomCarouselCallback!

        beforeEach {
            Exponea.shared = ExponeaInternal()
            IntegrationManager.shared.isStopped = false
            Exponea.shared.configure(with: self.configuration)
            manager = Exponea.shared.inAppContentBlocksManager!
            callback = CustomCarouselCallback()
            manager.anonymize()
        }

        it("date filter") {
            let date = Date()
            let bigDate = Date().addingTimeInterval(5)
            let firstInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(dateFilter: .init(enabled: true, fromDate: date, toDate: bigDate))
            var isIn = manager.applyDateFilter(message: firstInAppContentBlocks)
            expect(isIn).to(beTrue())
            waitUntil(timeout: .seconds(7)) { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    isIn = manager.applyDateFilter(message: firstInAppContentBlocks)
                    done()
                }
            }
            expect(isIn).to(beFalse())
        }
        
        it("Corrupted images") {
            // Stub network responses deterministically — previously this test made real HTTPS
            // calls to upload.wikimedia.org and flaked under slow/offline network.
            // Mockingjay auto-swizzles `URLSessionConfiguration.ephemeral` at `+load` time, which
            // is exactly what `hasHtmlImages` uses, so no production injection seam is needed.
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
            let validImageData = renderer.image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }.pngData()!
            MockingjayProtocol.addStub(
                matcher: { request in
                    request.url?.absoluteString.contains("/Gull_portrait_ca_usa.jpg") == true
                },
                builder: { _ in
                    let response = HTTPURLResponse(
                        url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/9/9a/Gull_portrait_ca_usa.jpg")!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "image/png"]
                    )!
                    return .success(response, .content(validImageData))
                }
            )
            MockingjayProtocol.addStub(
                matcher: { request in
                    request.url?.absoluteString.contains("/Gull_portrait_ca_usssssa.jpg") == true
                },
                builder: { _ in
                    let response = HTTPURLResponse(
                        url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/9/9a/Gull_portrait_ca_usssssa.jpg")!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return .success(response, .content(Data()))
                }
            )
            defer { MockingjayProtocol.removeAllStubs() }

            let rawHtml = "<html>" +
            "<body>" +
            "<img src='https://upload.wikimedia.org/wikipedia/commons/9/9a/Gull_portrait_ca_usa.jpg'>" +
            "<img src='https://upload.wikimedia.org/wikipedia/commons/9/9a/Gull_portrait_ca_usa.jpg'>" +
            "<div data-actiontype='close' onclick='alert('hello')'>Close</div>" +
            "<div data-link='https://example.com/1'>Action 1</div>" +
            "<div data-link='https://example.com/2'>Action 2</div>" +
            "</body></html>"
            let rawHtmlEmptyImages = "<html>" +
            "<body>" +
            "<div data-actiontype='close' onclick='alert('hello')'>Close</div>" +
            "<div data-link='https://example.com/1'>Action 1</div>" +
            "<div data-link='https://example.com/2'>Action 2</div>" +
            "</body></html>"
            let rawHtmlCorruptedImage = "<html>" +
            "<body>" +
            "<img src='https://upload.wikimedia.org/wikipedia/commons/9/9a/Gull_portrait_ca_usssssa.jpg'>" +
            "<div data-actiontype='close' onclick='alert('hello')'>Close</div>" +
            "<div data-link='https://example.com/1'>Action 1</div>" +
            "<div data-link='https://example.com/2'>Action 2</div>" +
            "</body></html>"
            // `hasHtmlImages` enforces `dispatchPrecondition(.notOnQueue(.main))` on its
            // implementation, so we must invoke it off-main. Quick test bodies run on main,
            // so we hop to a background queue and rendezvous via `waitUntil`.
            var result: Bool?
            var result2: Bool?
            var result3: Bool?
            waitUntil(timeout: .seconds(10)) { done in
                DispatchQueue.global(qos: .utility).async {
                    result = manager.hasHtmlImages(html: rawHtml)
                    result2 = manager.hasHtmlImages(html: rawHtmlEmptyImages)
                    result3 = manager.hasHtmlImages(html: rawHtmlCorruptedImage)
                    done()
                }
            }
            expect(result).to(equal(true))   // stubbed 200 with valid PNG
            expect(result2).to(equal(true))  // no images at all
            expect(result3).to(equal(false)) // stubbed 404 / empty body
        }

        it("hasHtmlImages consults InAppMessagesCache and skips the network on hit") {
            // Regression for the carousel cold-paint short-circuit: after HtmlNormalizer.asBase64Image
            // has baked images for offline rendering, every image URL is already on disk in
            // InAppMessagesCache. `hasHtmlImages` must consult that cache first and short-circuit
            // to `true` on any decodable hit, without issuing a network request.
            let uniqueSuffix = UUID().uuidString
            let cachedImageUrl = "https://example.test/\(uniqueSuffix).png"

            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
            let validImageData = renderer.image { ctx in
                UIColor.blue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }.pngData()!

            // Pre-populate the exact cache entry the production code will read.
            let cache = InAppMessagesCache()
            cache.saveImageData(at: cachedImageUrl, data: validImageData)

            // Counter shared between test and Mockingjay matcher/builder. The matcher runs
            // on every URL loaded through any `URLSessionConfiguration.ephemeral`-based session,
            // so it is the authoritative witness of whether the production code went to the
            // network at all for this URL.
            let networkInvocationCount = Atomic(wrappedValue: 0)
            MockingjayProtocol.addStub(
                matcher: { request in
                    request.url?.absoluteString == cachedImageUrl
                },
                builder: { _ in
                    networkInvocationCount.changeValue { $0 += 1 }
                    // Intentionally fail the network path: if the production code skips the
                    // cache and hits the network, the returned empty body will not decode
                    // as a UIImage and `hasHtmlImages` will return `false`, which the
                    // assertion below will catch.
                    let response = HTTPURLResponse(
                        url: URL(string: cachedImageUrl)!,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return .success(response, .content(Data()))
                }
            )
            defer { MockingjayProtocol.removeAllStubs() }

            let rawHtml = "<html><body>" +
            "<img src='\(cachedImageUrl)'>" +
            "</body></html>"

            var result: Bool?
            waitUntil(timeout: .seconds(5)) { done in
                DispatchQueue.global(qos: .utility).async {
                    result = manager.hasHtmlImages(html: rawHtml)
                    done()
                }
            }
            expect(result).to(equal(true))
            expect(networkInvocationCount.wrappedValue).to(equal(0))
        }

        it("check filtered") {
            let firstInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks()
            var isDone = false
            manager.addMessage(firstInAppContentBlocks)
            manager.filterCarouselData(placeholder: "asdas") { response in
                isDone = true
            } expiredCompletion: {
                
            }
            waitUntil(timeout: .seconds(3)) { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    done()
                }
            }
            expect(isDone).to(beTrue())
        }

        it("check inAppContentBlocks priority") {
            let firstInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(loadPriority: 1)
            let secondInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(loadPriority: 2)
            let thirdInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(loadPriority: 2)
            let fourthInAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(loadPriority: 2)
            let input = [
                firstInAppContentBlocks,
                secondInAppContentBlocks,
                thirdInAppContentBlocks,
                fourthInAppContentBlocks,
            ]
            let prioritized = manager.filterPriority(input: input)
            expect(prioritized[1]?.count).to(equal(1))
            expect(prioritized[2]?.count).toNot(equal(10))
            expect(prioritized[2]?.count).to(equal(3))
        }
        
        it("check TTL") {
            let ttlSeen = Date()
            let inAppContentBlocks = [SampleInAppContentBlocks.getSampleIninAppContentBlocks(personalized: .getSample(status: .ok, ttlSeen: ttlSeen))]
            let savedTags = inAppContentBlocks[0].tags ?? []
            let messagesNeeedToRefresh = inAppContentBlocks.first(where: { inAppContentBlocks in
                if let tags = inAppContentBlocks.tags, tags == savedTags,
                   let ttlSeen = inAppContentBlocks.personalizedMessage?.ttlSeen,
                   let ttl = inAppContentBlocks.personalizedMessage?.ttlSeconds,
                   inAppContentBlocks.content == nil {
                    return Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
                }
                return false
            })
            expect(messagesNeeedToRefresh).toEventually(beNil(), timeout: .seconds(2))
            var messagesNeeedToRefreshTrue: InAppContentBlockResponse?
            waitUntil(timeout: .seconds(6)) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    messagesNeeedToRefreshTrue = inAppContentBlocks.first(where: { inAppContentBlocks in
                        if let tag = inAppContentBlocks.tags, tag == savedTags,
                           let ttlSeen = inAppContentBlocks.personalizedMessage?.ttlSeen,
                           let ttl = inAppContentBlocks.personalizedMessage?.ttlSeconds,
                           inAppContentBlocks.content == nil {
                            return Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
                        }
                        return false
                    })
                    done()
                }
            }
            expect(messagesNeeedToRefreshTrue).toEventuallyNot(beNil(), timeout: .seconds(1))
        }
        
        it("filter - always") {
            var inAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "filter - always - msg123 - \(UUID().uuidString)",
                personalized: .getSample(
                    status: .ok,
                    ttlSeen: Date()
                )
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            expect(manager.getFilteredMessage(message: inAppContentBlocks)).toEventually(beTrue(), timeout: .seconds(4))
        }
        
        it("filter - interaction") {
            var inAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "filter - interaction - msg123 - \(UUID().uuidString)",
                frequency: .untilVisitorInteracts,
                personalized: .getSample(
                    status: .ok,
                    ttlSeen: Date()
                )
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
            }
            expect(manager.getFilteredMessage(message: inAppContentBlocks)).toEventually(beTrue(), timeout: .seconds(3))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.1) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            expect(manager.getFilteredMessage(message: inAppContentBlocks)).toEventually(beFalse(), timeout: .seconds(4))
        }
        
        it("filter - seen") {
            var inAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "filter - seen - msg123 - \(UUID().uuidString)",
                frequency: .onlyOnce,
                personalized: .getSample(
                    status: .ok,
                    ttlSeen: Date()
                )
            )
            expect(manager.getFilteredMessage(message: inAppContentBlocks)).toEventually(beTrue(), timeout: .seconds(3))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) {
                manager.updateDisplayedState(for: inAppContentBlocks.id)
                manager.updateInteractedState(for: inAppContentBlocks.id)
            }
            expect(manager.getFilteredMessage(message: inAppContentBlocks)).toEventually(beFalse(), timeout: .seconds(4))
        }
        
        it("prefetch") {
            let inAppContentBlocks = [
                SampleInAppContentBlocks.getSampleIninAppContentBlocks(placeholders: ["ph1"], personalized: .getSample(status: .ok, ttlSeen: Date())),
                SampleInAppContentBlocks.getSampleIninAppContentBlocks(placeholders: ["ph1"], personalized: .getSample(status: .ok, ttlSeen: Date())),
                SampleInAppContentBlocks.getSampleIninAppContentBlocks(placeholders: ["ph1"], personalized: .getSample(status: .ok, ttlSeen: Date())),
                SampleInAppContentBlocks.getSampleIninAppContentBlocks(placeholders: ["ph2"], personalized: .getSample(status: .ok, ttlSeen: Date())),
            ]
            expect(manager.prefetchPlaceholdersWithIds(input: inAppContentBlocks, ids: ["ph1"]).count).to(be(3))
            expect(manager.prefetchPlaceholdersWithIds(input: inAppContentBlocks, ids: ["ph2"]).count).to(be(1))
            expect(manager.prefetchPlaceholdersWithIds(input: inAppContentBlocks, ids: ["ph1", "ph2"]).count).to(be(4))
            expect(manager.prefetchPlaceholdersWithIds(input: inAppContentBlocks, ids: [""]).count).to(be(0))
        }
        
        it("queue") {
            var inAppContentBlocks = SampleInAppContentBlocks.getSampleIninAppContentBlocks(frequency: .onlyOnce, personalized: .getSample(status: .ok, ttlSeen: Date()))
            var completionValue: Int = 0
            waitUntil(timeout: .seconds(25)) { done in
                for i in 0..<11 {
                    manager.refreshStaticViewContent(staticQueueData: .init(tag: inAppContentBlocks.tags?.first ?? 0, placeholderId: inAppContentBlocks.name, completion: { _ in
                        completionValue = i
                        if i == 10 {
                            DispatchQueue.main.async { done() }
                        }
                    }))
                }
            }
            expect(completionValue).to(be(10))
        }
        
        it("message changed") {
            var wasMessageChanged = false
            let callback = CustomCarouselCallback()
            let view = CarouselInAppContentBlockView(placeholder: "placeholder", behaviourCallback: callback)
                
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                view.state = .refresh
            }
            waitUntil(timeout: .seconds(2)) { done in
                callback.onMessageChangedCallback = {
                    wasMessageChanged = true
                    DispatchQueue.main.async { done() }
                }
            }
            expect(wasMessageChanged).to(beTrue())
        }
        
        it("overlimit") {
            let array: [Int] = [1, 2, 3, 4, 5]
            let maxOverLimit = 10
            let result = array.prefix(maxOverLimit)
            expect(result.count).to(be(5))
        }

        it("multipler") {
            let view = CarouselInAppContentBlockView(placeholder: "")
            let a = view.makeDuplicate(input: [.init(html: "a", tag: 1)])
            expect(a.count).to(be(1))
            let b = view.makeDuplicate(input: [.init(html: "a", tag: 1), .init(html: "a", tag: 2), .init(html: "b", tag: 3)])
            expect(b.count).to(be(150))
            expect(b.filter({ $0.html == "b" }).count).to(be(50))
            let c = view.makeDuplicate(input: [
                .init(html: "a", tag: 1),
                .init(html: "a", tag: 2),
                .init(html: "b", tag: 3),
                .init(html: "b", tag: 4),
                .init(html: "c", tag: 5),
                .init(html: "c", tag: 6)
            ])
            expect(c.count).to(be(150))
            expect(c.filter({ $0.tag == 6 }).count).to(be(25))
            let d = view.makeDuplicate(input: [
                .init(html: "a", tag: 1),
                .init(html: "a", tag: 2),
                .init(html: "b", tag: 3),
                .init(html: "b", tag: 4),
                .init(html: "c", tag: 5),
                .init(html: "c", tag: 6),
                .init(html: "d", tag: 7),
                .init(html: "d", tag: 8),
                .init(html: "e", tag: 9),
                .init(html: "e", tag: 10),
                .init(html: "f", tag: 11)
            ])
            expect(d.count).to(be(110))
            expect(d.filter({ $0.tag == 6 }).count).to(be(10))
            expect(d.filter({ $0.html == "c" }).count).to(be(20))
        }

        it("is valid check") {
            let messageExpired: StaticReturnData = .init(
                html: "",
                tag: 0,
                message: .init(
                    id: UUID().uuidString,
                    name: "",
                    dateFilter: .init(
                        enabled: false,
                        fromDate: nil,
                        toDate: nil
                    ),
                    frequency: .untilVisitorInteracts,
                    placeholders: [""],
                    tags: [],
                    loadPriority: 100,
                    content: nil,
                    personalized: .getSample(status: .ok, ttlSeen: Date().addingTimeInterval(-10000))
                )
            )
            
             var userDefaults: UserDefaults = {
                if UserDefaults(suiteName: Constants.General.userDefaultsSuite) == nil {
                    UserDefaults.standard.addSuite(named: Constants.General.userDefaultsSuite)
                }
                return UserDefaults(suiteName: Constants.General.userDefaultsSuite)!
            }()
            
            let store = InAppContentBlockDisplayStatusStore(userDefaults: userDefaults)

            var messageInvalidInteracted: StaticReturnData = .init(
                html: "",
                tag: 0,
                message: .init(
                    id: UUID().uuidString,
                    name: "",
                    dateFilter: .init(
                        enabled: false,
                        fromDate: nil,
                        toDate: nil
                    ),
                    frequency: .untilVisitorInteracts,
                    placeholders: [""],
                    tags: [],
                    loadPriority: 100,
                    content: nil,
                    personalized: .getSample(status: .ok, ttlSeen: Date())
                )
            )
            store.didInteract(with: messageInvalidInteracted.message?.id ?? "", at: Date().addingTimeInterval(4000))

            var messageInvalidShowed: StaticReturnData = .init(
                html: "",
                tag: 0,
                message: .init(
                    id: UUID().uuidString,
                    name: "",
                    dateFilter: .init(
                        enabled: false,
                        fromDate: nil,
                        toDate: nil
                    ),
                    frequency: .oncePerVisit,
                    placeholders: [""],
                    tags: [],
                    loadPriority: 100,
                    content: nil,
                    personalized: .getSample(status: .ok, ttlSeen: Date())
                )
            )
            store.didDisplay(of: messageInvalidShowed.message?.id ?? "", at: Date().addingTimeInterval(4000))

            var messageValid: StaticReturnData = .init(
                html: "",
                tag: 0,
                message: .init(
                    id: UUID().uuidString,
                    name: "",
                    dateFilter: .init(
                        enabled: false,
                        fromDate: nil,
                        toDate: nil
                    ),
                    frequency: .always,
                    placeholders: [""],
                    tags: [],
                    loadPriority: 100,
                    content: nil,
                    personalized: .getSample(status: .ok, ttlSeen: Date().addingTimeInterval(4000))
                )
            )

            var isMessageExpiredAndValid = false
            waitUntil(timeout: .seconds(2)) { done in
                manager.isMessageValid(message: messageExpired.message!) { _ in
                } refreshCallback: {
                    isMessageExpiredAndValid = true
                    DispatchQueue.main.async { done() }
                }
            }
            expect(isMessageExpiredAndValid).to(beTrue())

            var isMessageInvalid = false
            waitUntil(timeout: .seconds(2)) { done in
                manager.isMessageValid(message: messageInvalidInteracted.message!) { isValid in
                    isMessageInvalid = !isValid
                    DispatchQueue.main.async { done() }
                } refreshCallback: {
                }
            }
            expect(isMessageInvalid).to(beTrue())

            var isMessageInvalidShowed = false
            waitUntil(timeout: .seconds(2)) { done in
                manager.isMessageValid(message: messageInvalidShowed.message!) { isValid in
                    isMessageInvalidShowed = !isValid
                    DispatchQueue.main.async { done() }
                } refreshCallback: {
                }
            }
            expect(isMessageInvalidShowed).to(beTrue())

            var isMessageValid = false
            waitUntil(timeout: .seconds(2)) { done in
                manager.isMessageValid(message: messageValid.message!) { isValid in
                    isMessageValid = isValid
                    DispatchQueue.main.async { done() }
                } refreshCallback: {
                }
            }
            expect(isMessageValid).to(beTrue())
        }
        
        it("batch static requests with empty placeholderId receive empty result") {
            var completionCalled = false
            waitUntil(timeout: .seconds(5)) { done in
                manager.refreshStaticViewContent(staticQueueData: .init(
                    tag: 0,
                    placeholderId: "",
                    completion: { result in
                        completionCalled = true
                        expect(result.html).to(beEmpty())
                        expect(result.message).to(beNil())
                        DispatchQueue.main.async { done() }
                    }
                ))
            }
            expect(completionCalled).to(beTrue())
        }

        // Regression guard for C3: `CarouselInAppContentBlockView.reload` is `open` on a
        // `public` class — subclasses / host apps may call from any thread. A trap-on-background
        // contract was a release-build regression introduced during the batching refactor.
        it("CarouselInAppContentBlockView.reload is safe to call from a background queue") {
            let view = CarouselInAppContentBlockView(placeholder: "carousel_bg_test")
            waitUntil(timeout: .seconds(3)) { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    view.reload(isTriggered: false)
                    DispatchQueue.main.async { done() }
                }
            }
            expect(true).to(beTrue())
        }

        // Regression guard for C3: `refreshStaticViewContent` is public-surface via
        // `InAppContentBlocksManagerType` and must not trap when invoked off the main queue.
        it("refreshStaticViewContent is safe to call from a background queue") {
            var completionCalled = false
            waitUntil(timeout: .seconds(5)) { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    manager.refreshStaticViewContent(staticQueueData: .init(
                        tag: 7,
                        placeholderId: "",
                        completion: { _ in
                            completionCalled = true
                            DispatchQueue.main.async { done() }
                        }
                    ))
                }
            }
            expect(completionCalled).to(beTrue())
        }

        it("multiple batched requests all receive completions") {
            let requestCount = 5
            var completionCount = 0
            waitUntil(timeout: .seconds(10)) { done in
                for i in 0..<requestCount {
                    manager.refreshStaticViewContent(staticQueueData: .init(
                        tag: i,
                        placeholderId: "placeholder_\(i)",
                        completion: { _ in
                            completionCount += 1
                            if completionCount == requestCount {
                                DispatchQueue.main.async { done() }
                            }
                        }
                    ))
                }
            }
            expect(completionCount).to(equal(requestCount))
        }

        it("ttlSeen is preserved after message update") {
            let msgId = "ttl-test-\(UUID().uuidString)"
            let ttlDate = Date().addingTimeInterval(-100)
            let message = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: msgId,
                personalized: .getSample(status: .ok, ttlSeen: ttlDate)
            )
            manager.addMessage(message)
            let concreteManager = manager as! InAppContentBlocksManager
            let stored = concreteManager.inAppContentBlockMessages.first(where: { $0.id == msgId })
            expect(stored).toNot(beNil())
            expect(stored?.personalizedMessage?.ttlSeen).to(equal(ttlDate))
        }

        it("addMessage is safe under concurrent access") {
            let concreteManager = manager as! InAppContentBlocksManager
            let group = DispatchGroup()
            let iterations = 50
            for i in 0..<iterations {
                group.enter()
                DispatchQueue.global().async {
                    manager.addMessage(SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                        id: "concurrent-\(i)"
                    ))
                    group.leave()
                }
            }
            waitUntil(timeout: .seconds(5)) { done in
                group.notify(queue: .main) { done() }
            }
            let concurrentMessages = concreteManager.inAppContentBlockMessages.filter {
                $0.id.hasPrefix("concurrent-")
            }
            expect(concurrentMessages.count).to(equal(iterations))
        }

        // Regression guard for the "only one carousel renders" bug caused by a single shared
        // validation token being overwritten when multiple `CarouselInAppContentBlockView`s for
        // different placeholders started loading in parallel. Each placeholder must own its own
        // token; loading placeholder B must not invalidate placeholder A's in-flight validation.
        it("loadMessagesForCarousel keeps per-placeholder validation tokens independent") {
            let concreteManager = manager as! InAppContentBlocksManager
            manager.addMessage(SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "carousel-indep-a-\(UUID().uuidString)",
                placeholders: ["carousel_a"]
            ))
            manager.addMessage(SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "carousel-indep-b-\(UUID().uuidString)",
                placeholders: ["carousel_b"]
            ))

            // Token writes happen synchronously inside `loadMessagesForCarousel` before the
            // async network call, so we can assert on them without waiting for completion.
            // Called through the concrete type because `loadMessagesForCarousel` is no longer
            // part of the public `InAppContentBlocksManagerType` surface.
            concreteManager.loadMessagesForCarousel(
                placeholder: "carousel_a",
                initialCompletion: nil,
                completion: nil
            )
            let tokenA = concreteManager.carouselValidationTokens["carousel_a"]
            expect(tokenA).toNot(beNil())

            concreteManager.loadMessagesForCarousel(
                placeholder: "carousel_b",
                initialCompletion: nil,
                completion: nil
            )
            let tokenB = concreteManager.carouselValidationTokens["carousel_b"]
            expect(tokenB).toNot(beNil())
            // Crucially, A's token must still be intact — the B reload must not have clobbered it.
            expect(concreteManager.carouselValidationTokens["carousel_a"]).to(equal(tokenA))
            expect(tokenB).toNot(equal(tokenA))
        }

        // Regression guard: two back-to-back reload() calls for the SAME placeholder
        // must NOT both issue a personalization fetch. A production trace captured two
        // identical POST /inappcontentblocks bursts 216 ms apart for `example_carousel`,
        // costing ~300 ms of wall-clock and doubling HTML-normalization work on the
        // cold-render path.
        //
        // Observable proxy: `carouselValidationTokens[placeholder]`. `loadMessagesForCarousel`
        // rotates this token synchronously on the calling thread *right before* invoking
        // the provider — so token rotations are a 1:1 synchronous proxy for provider
        // invocations on the same main thread. Under the dedup fix, the second caller
        // short-circuits on the in-flight map BEFORE rotating the token; under the
        // pre-fix code each call unconditionally rotates, producing two distinct UUIDs.
        //
        // Why not spy on the repository directly: `InAppContentBlocksDataProvider.serverRepository`
        // is a `private lazy var` that captures `Exponea.shared.repository` on first access,
        // and `ExponeaInternal.configure` triggers that first access during `loadInAppContentBlockMessages`
        // — before any test-side swap. A token-level proxy avoids adding a second injection seam.
        it("two loadMessagesForCarousel calls for the same placeholder share one in-flight fetch") {
            let concreteManager = manager as! InAppContentBlocksManager
            let placeholder = "carousel_dedup_\(UUID().uuidString)"
            // Prime the static cache so `idsForDownload` is non-empty — matches the
            // production scenario captured in the log trace where the placeholder has
            // known message IDs before the personalization fetch fires.
            manager.addMessage(SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "dedup-msg-\(UUID().uuidString)",
                placeholders: [placeholder]
            ))

            concreteManager.loadMessagesForCarousel(
                placeholder: placeholder,
                initialCompletion: nil,
                completion: nil
            )
            let firstToken = concreteManager.carouselValidationTokens[placeholder]
            expect(firstToken).toNot(beNil())

            concreteManager.loadMessagesForCarousel(
                placeholder: placeholder,
                initialCompletion: nil,
                completion: nil
            )
            let secondToken = concreteManager.carouselValidationTokens[placeholder]

            // Under dedup: the second call attaches as a waiter on the first in-flight
            // fetch and does NOT rotate the token → secondToken == firstToken.
            // Pre-dedup (the failing-first baseline this test is designed to catch):
            // each call rotates unconditionally → secondToken != firstToken.
            expect(secondToken).to(equal(firstToken))
        }

        // Stale-result-drop regression: a late-arriving personalization callback from
        // a superseded fetch must NOT consume the current in-flight record (which
        // belongs to a newer fetch). Without the guard, a naïve
        // `map.removeValue(forKey: placeholder)` in the callback would orphan the newer
        // run's waiters. Under the `claimInFlightCarouselFetch` guard, the mismatched
        // `validationToken` makes the claim a no-op, leaving the newer record intact.
        it("stale personalized-fetch callback does not consume a newer in-flight record") {
            let concreteManager = manager as! InAppContentBlocksManager
            let placeholder = "carousel_stale_\(UUID().uuidString)"

            // Simulate a newer fetch that has taken over the placeholder's in-flight slot
            // after some older fetch was kicked off. The newer fetch owns `newerToken`
            // and has two waiters queued (the initiator + a subsequent caller that
            // attached via dedup).
            let olderToken = UUID()
            let newerToken = UUID()
            var initialFires = 0
            var completionFires = 0
            let newerRecord = CarouselInFlightFetch(
                validationToken: newerToken,
                waiters: [
                    (
                        initial: { initialFires += 1 },
                        completion: { completionFires += 1 }
                    ),
                    (
                        initial: { initialFires += 1 },
                        completion: { completionFires += 1 }
                    )
                ]
            )
            concreteManager.$carouselInFlightFetches.changeValue { $0[placeholder] = newerRecord }

            // The older fetch's callback finally arrives and attempts to claim — with
            // ITS own (now-stale) token. The guard must refuse, return nil, and leave
            // the newer record + its waiters untouched.
            let claimedByStale = concreteManager.claimInFlightCarouselFetch(
                placeholder: placeholder,
                validationToken: olderToken
            )
            expect(claimedByStale).to(beNil())
            expect(concreteManager.carouselInFlightFetches[placeholder]?.validationToken).to(equal(newerToken))
            expect(concreteManager.carouselInFlightFetches[placeholder]?.waiters.count).to(equal(2))
            expect(initialFires).to(equal(0))
            expect(completionFires).to(equal(0))

            // The newer fetch's own callback then arrives with the matching token and
            // correctly claims the record. Waiters are returned to the caller (who will
            // fan them out via `broadcastInitial` / `broadcastCompletion`) and the map
            // slot is cleared.
            let claimedByCurrent = concreteManager.claimInFlightCarouselFetch(
                placeholder: placeholder,
                validationToken: newerToken
            )
            expect(claimedByCurrent?.count).to(equal(2))
            expect(concreteManager.carouselInFlightFetches[placeholder]).to(beNil())
            // Manually fan out to verify the waiters are the ones we registered (not
            // stubs created by the claim path) — this also catches any accidental
            // truncation of the waiters array during the claim.
            claimedByCurrent?.forEach { waiter in
                waiter.initial?()
                waiter.completion?()
            }
            expect(initialFires).to(equal(2))
            expect(completionFires).to(equal(2))
        }

        // Regression guard for C1 (TOCTOU): after the token rotates, a stale worker's write of
        // `.valid` / `.corrupted` must NOT overwrite the fresh run's `.pending`. The pre-fix
        // `updateImageValidationState(messageId:isCorrupted:)` did not check the token, so the
        // final state write from a superseded run would clobber the current run's state.
        it("stale worker's final state write is a no-op when token has rotated") {
            let concreteManager = manager as! InAppContentBlocksManager
            let messageId = "stale-race-\(UUID().uuidString)"
            let placeholder = "carousel_race_\(UUID().uuidString)"

            // Run 1 starts — token T1 registered, `.pending` written.
            let tokenRun1 = UUID()
            concreteManager.$carouselValidationTokens.changeValue { $0[placeholder] = tokenRun1 }
            concreteManager.$imageValidationStates.changeValue { $0[messageId] = .pending }

            // Run 2 supersedes Run 1 — token T2 registered, fresh `.pending` written.
            let tokenRun2 = UUID()
            concreteManager.$carouselValidationTokens.changeValue { $0[placeholder] = tokenRun2 }
            concreteManager.$imageValidationStates.changeValue { $0[messageId] = .pending }

            // Run 1's stale worker attempts to finalize — under the fix, this is a no-op because
            // `placeholder`'s active token is T2, not T1.
            concreteManager.updateImageValidationState(
                messageId: messageId,
                placeholder: placeholder,
                validationToken: tokenRun1,
                isCorrupted: false
            )

            expect(concreteManager.imageValidationStates[messageId]).to(equal(.pending))

            // Meanwhile, Run 2's worker finalizing with the current token T2 DOES write through.
            concreteManager.updateImageValidationState(
                messageId: messageId,
                placeholder: placeholder,
                validationToken: tokenRun2,
                isCorrupted: true
            )
            expect(concreteManager.imageValidationStates[messageId]).to(equal(.corrupted))
        }

        describe("InAppContentBlockResponse") {
            let json: [String: Any] = [
                "id": "test-id",
                "name": "Test Name",
                "date_filter": [
                    "enabled": true,
                    "from_date": "2024-01-01T00:00:00Z",
                    "to_date": "2024-12-31T23:59:59Z"
                ],
                "placeholders": ["a", "b"],
                "frequency": "only_once",
                "load_priority": 5,
                "content_type": "html",
                "consent_category_tracking": "analytics"
            ]
            it("should decode and allow mutation of extra properties") {
                let json: [String: Any] = [
                    "id": "test-id",
                    "name": "Test Name",
                    "date_filter": [
                        "enabled": true,
                        "from_date": "2025-01-01T00:00:00Z",
                        "to_date": "2025-12-31T23:59:59Z"
                    ],
                    "frequency": "only_once",
                    "load_priority": 5,
                    "content_type": "html",
                    "consent_category_tracking": "analytics",
                    "placeholders": ["a", "b"]
                ]

                let data = try! JSONSerialization.data(withJSONObject: json)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                var block = try! decoder.decode(InAppContentBlockResponse.self, from: data)

                expect(block.id) == "test-id"
                expect(block.name) == "Test Name"
                expect(block.dateFilter.enabled) == true
                expect(block.dateFilter.fromDate).toNot(beNil())
                expect(block.placeholders).to(equal(["a", "b"]))
                expect(block.frequency) == .onlyOnce
                expect(block.loadPriority) == 5
                expect(block.contentType) == .html
                expect(block.trackingConsentCategory) == "analytics"

                expect(block.tags).to(equal([]))
                expect(block.sessionStart).toNot(beNil())
                expect(block.indexPath).to(beNil())
                expect(block.isCorruptedImage) == false
                expect(block.status).to(beNil())

                let now = Date()
                block.tags = [1, 2, 3]
                block.sessionStart = now
                block.indexPath = IndexPath(row: 4, section: 2)
                block.isCorruptedImage = true
                block.status = InAppContentBlocksDisplayStatus(displayed: now, interacted: now.addingTimeInterval(5))

                expect(block.tags).to(equal([1, 2, 3]))
                expect(block.sessionStart).to(equal(now))
                expect(block.indexPath).to(equal(IndexPath(row: 4, section: 2)))
                expect(block.isCorruptedImage).to(beTrue())
                expect(block.status?.displayed).to(equal(now))
                expect(block.status?.interacted).to(equal(now.addingTimeInterval(5)))
            }
            it("decodes and encodes properly including optional and extra attributes") {
                let data = try! JSONSerialization.data(withJSONObject: json)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let block = try! decoder.decode(InAppContentBlockResponse.self, from: data)
                
                expect(block.id) == "test-id"
                expect(block.name) == "Test Name"
                expect(block.dateFilter.enabled) == true
                expect(block.dateFilter.fromDate).toNot(beNil())
                expect(block.placeholders).to(equal(["a", "b"]))
                expect(block.frequency) == .onlyOnce
                expect(block.loadPriority) == 5
                expect(block.contentType) == .html
                expect(block.trackingConsentCategory) == "analytics"
                
                expect(block.tags).to(equal([]))
                expect(block.sessionStart).toNot(beNil())
                expect(block.indexPath).to(beNil())
                expect(block.isCorruptedImage) == false
                expect(block.status).to(beNil())
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                let encoded = try! encoder.encode(block)
                let roundTrip = try! decoder.decode(InAppContentBlockResponse.self, from: encoded)
                expect(roundTrip.id) == "test-id"
                expect(roundTrip.placeholders) == ["a", "b"]
            }
        }

        // Regression guard: CarouselInAppContentBlockView must not be retained by its
        // own Combine cancellables. Strong-self captures in the notification sinks
        // created a cycle that prevented dealloc after identifyCustomer(...) and could
        // surface previous-customer content.
        it("CarouselInAppContentBlockView is deallocated when the host releases its strong reference") {
            weak var weakView: CarouselInAppContentBlockView?
            autoreleasepool {
                let view = CarouselInAppContentBlockView(placeholder: "ph_carousel_dealloc")
                weakView = view
                // The host releases its only strong reference here.
                view.release()
            }
            // Combine subscriptions are cancelled and the array is drained on `release()`,
            // so the view should be deallocated immediately after the autoreleasepool drains.
            expect(weakView).toEventually(beNil(), timeout: .seconds(2))
        }

        // Regression guard: release() must drop all Combine subscriptions.
        // Before the fix, release() called removeObserver(self, ...) — a no-op for
        // publisher-based subscriptions — and the cancellables array remained populated.
        it("CarouselInAppContentBlockView.release() cancels all Combine subscriptions") {
            let view = CarouselInAppContentBlockView(placeholder: "ph_carousel_cancel")
            expect(view.cancellables).toNot(beEmpty())
            view.release()
            expect(view.cancellables).to(beEmpty())
        }

        // Regression guard (cell-callback case): the cell wiring in `cellForItemAt`
        // previously assigned `cell.touchCallback = saveCurrentTimer` and
        // `cell.releaseCallback = startTimer` — unbound instance method refs that Swift
        // desugars into strong-self closures. That formed a fourth retain cycle
        // (self -> collectionView -> cell -> closure -> self) which is invisible to the
        // other two regression tests because they never trigger `cellForItemAt`.
        //
        // Test seam usage: `_testOnly_vendCellAtFirstIndex` vends through the view's own
        // (private, lazy) `collectionView`. This matters — vending through a scratch
        // collection view local to the test would NOT pin the cycle, because a local
        // collection view goes out of scope at the end of the autoreleasepool, releases
        // the cell, the cell releases its closures, and the view dealloca regardless of
        // the bug. Using `self.collectionView` mirrors the production retention graph
        // (the carousel keeps its own collection view alive via a stored property).
        it("CarouselInAppContentBlockView is deallocated even after a cell has been vended") {
            weak var weakView: CarouselInAppContentBlockView?
            autoreleasepool {
                let view = CarouselInAppContentBlockView(placeholder: "ph_carousel_cell_dealloc")
                weakView = view
                view._testOnly_seedData([StaticReturnData(html: "<html></html>", tag: 0)])
                view._testOnly_vendCellAtFirstIndex()
                view.release()
            }
            expect(weakView).toEventually(beNil(), timeout: .seconds(2))
        }

        // MARK: - WebContent process termination recovery (CarouselContentBlockViewCell)
        //
        // When iOS jetsams a cell's WebContent process (notably while the app
        // is backgrounded with the device locked), the cell must transparently
        // reissue the HTML it last rendered so the user does not return to a
        // blank carousel. The cache is `lastLoadedHtml`; it MUST be set on
        // every successful `loadHtml` and MUST be cleared on `prepareForReuse`
        // so a recycled cell never recovers with stale content from a previous
        // index.

        it("CarouselContentBlockViewCell.webViewWebContentProcessDidTerminate reissues the last loaded html") {
            let cell = CarouselContentBlockViewCell(frame: .zero)
            let html = "<html><body>recover-me</body></html>"
            cell.loadHtml(html: html, assignedMessage: nil, placeholder: "ph_recover")

            let spy = LoadHTMLStringSpyWebView()
            cell.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(equal([html]))
        }

        it("CarouselContentBlockViewCell.webViewWebContentProcessDidTerminate is a no-op when no html has been loaded") {
            // Termination can fire on a freshly-vended cell that has not been
            // told to render anything yet (e.g. the WebContent process died
            // mid-`cellForItemAt`). Reissuing an empty/nil cache would either
            // crash or paint a blank page and clobber whatever recovery the
            // real `loadHtml` is about to do.
            let cell = CarouselContentBlockViewCell(frame: .zero)

            let spy = LoadHTMLStringSpyWebView()
            cell.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(beEmpty())
        }

        it("CarouselContentBlockViewCell.webViewWebContentProcessDidTerminate is a no-op after prepareForReuse clears the cache") {
            // This is the key correctness property of clearing `lastLoadedHtml`
            // in `prepareForReuse`: a recycled cell must NOT auto-recover into
            // the previous index's HTML when the WebContent process is killed
            // before the new `loadHtml` lands. Otherwise the user would briefly
            // see the previous message under their finger after a swipe.
            let cell = CarouselContentBlockViewCell(frame: .zero)
            cell.loadHtml(html: "<html>previous</html>", assignedMessage: nil, placeholder: "ph_recover")
            cell.prepareForReuse()

            let spy = LoadHTMLStringSpyWebView()
            cell.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(beEmpty())
        }

        it("CarouselContentBlockViewCell.webViewWebContentProcessDidTerminate is a no-op when the cached html is empty") {
            // Empty HTML is a sentinel for "no message" (see `onNoMessageFound`).
            // Reissuing it on recovery would surface a blank webview to the user
            // and pollute the spy/IPC channel with no benefit.
            let cell = CarouselContentBlockViewCell(frame: .zero)
            cell.loadHtml(html: "", assignedMessage: nil, placeholder: "ph_recover")

            let spy = LoadHTMLStringSpyWebView()
            cell.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(beEmpty())
        }

        // MARK: - WebContent process termination recovery (WKWebViewHeightCalculator)
        //
        // The calculator is *off-screen* (never enters the view hierarchy), so
        // unlike a cell's webview, iOS does NOT auto-restart its WebContent
        // process after termination. Without an explicit reissue, no
        // `didFinish` ever reaches `heightUpdate` and the carousel stays pinned
        // at its initial 1pt placeholder height — the user returns to an
        // invisible carousel. These specs pin that the cached `lastLoadedHtml`
        // is the recovery payload, exactly as for the cell.

        it("WKWebViewHeightCalculator.webViewWebContentProcessDidTerminate reissues the last loaded html") {
            let calculator = WKWebViewHeightCalculator()
            let html = "<html><body style='height:200px'></body></html>"
            calculator.loadHtml(placedholderId: "ph_calc_recover", html: html)

            let spy = LoadHTMLStringSpyWebView()
            calculator.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(equal([html]))
        }

        it("WKWebViewHeightCalculator.webViewWebContentProcessDidTerminate is a no-op when no html has been loaded") {
            let calculator = WKWebViewHeightCalculator()

            let spy = LoadHTMLStringSpyWebView()
            calculator.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(beEmpty())
        }

        it("WKWebViewHeightCalculator.webViewWebContentProcessDidTerminate is a no-op when the cached html is empty") {
            // `loadHtml(placedholderId:html:)` short-circuits on empty input
            // (it fires `heightUpdate(0)` and intentionally does NOT populate
            // `lastLoadedHtml`), so the recovery path must do the same — no
            // spurious empty navigation on termination.
            let calculator = WKWebViewHeightCalculator()
            calculator.loadHtml(placedholderId: "ph_calc_recover", html: "")

            let spy = LoadHTMLStringSpyWebView()
            calculator.webViewWebContentProcessDidTerminate(spy)

            expect(spy.loadedHtmlStrings).to(beEmpty())
        }

        // MARK: - filterCarouselData expiration scoping
        //
        // The TTL-expiration check must be scoped to messages of the *queried*
        // placeholder. Including unrelated placeholders' expired messages
        // causes a permanent refresh loop because `loadMessagesForCarousel`
        // only re-fetches the queried placeholder, so unrelated expirations
        // are never resolved → `expiredCompletion` fires forever → the
        // carousel never paints.

        it("filterCarouselData ignores expired messages in unrelated placeholders so it cannot deadlock on TTL refresh") {
            // Reproduces the production scenario: app returns from a long
            // background; messages on `ph_other` are past their TTL but
            // `ph_under_test` has fresh content. The carousel for
            // `ph_under_test` MUST be allowed to paint.
            let validForUnderTest = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "valid-under-test-\(UUID().uuidString)",
                placeholders: ["ph_under_test"],
                personalized: .getSample(status: .ok, ttlSeen: Date())
            )
            let expiredOnUnrelated = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "expired-other-\(UUID().uuidString)",
                placeholders: ["ph_other"],
                personalized: .getSample(status: .ok, ttlSeen: Date(timeIntervalSinceNow: -3600))
            )
            manager.addMessage(validForUnderTest)
            manager.addMessage(expiredOnUnrelated)

            var continued: [InAppContentBlockResponse]?
            var expiredCompletionFired = false
            manager.filterCarouselData(
                placeholder: "ph_under_test",
                continueCallback: { continued = $0 },
                expiredCompletion: { expiredCompletionFired = true }
            )

            expect(expiredCompletionFired).to(beFalse())
            expect(continued).toNot(beNil())
            expect(continued?.contains(where: { $0.id == validForUnderTest.id })).to(beTrue())
            // Sanity: an unrelated placeholder's message must never appear in
            // the result for `ph_under_test`.
            expect(continued?.contains(where: { $0.id == expiredOnUnrelated.id })).to(beFalse())
        }

        it("filterCarouselData triggers expiredCompletion when the queried placeholder itself has expired messages") {
            // Inverse of the deadlock guard: when the QUERIED placeholder
            // genuinely has expired content, the SDK must request a refresh —
            // otherwise the carousel would paint stale messages.
            let expiredForUnderTest = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "expired-under-test-\(UUID().uuidString)",
                placeholders: ["ph_under_test"],
                personalized: .getSample(status: .ok, ttlSeen: Date(timeIntervalSinceNow: -3600))
            )
            manager.addMessage(expiredForUnderTest)

            var continued: [InAppContentBlockResponse]?
            var expiredCompletionFired = false
            manager.filterCarouselData(
                placeholder: "ph_under_test",
                continueCallback: { continued = $0 },
                expiredCompletion: { expiredCompletionFired = true }
            )

            expect(expiredCompletionFired).to(beTrue())
            expect(continued).to(beNil())
        }

        it("filterCarouselData returns only the queried placeholder's valid messages even when unrelated placeholders carry both valid and expired ones") {
            // Stronger version of the deadlock guard: the result set must be
            // strictly scoped to the queried placeholder regardless of what
            // mixture of states sits in unrelated placeholders.
            let validForUnderTest = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "valid-under-test-\(UUID().uuidString)",
                placeholders: ["ph_under_test"],
                personalized: .getSample(status: .ok, ttlSeen: Date())
            )
            let validForOther = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "valid-other-\(UUID().uuidString)",
                placeholders: ["ph_other"],
                personalized: .getSample(status: .ok, ttlSeen: Date())
            )
            let expiredForOther = SampleInAppContentBlocks.getSampleIninAppContentBlocks(
                id: "expired-other-\(UUID().uuidString)",
                placeholders: ["ph_other"],
                personalized: .getSample(status: .ok, ttlSeen: Date(timeIntervalSinceNow: -3600))
            )
            manager.addMessage(validForUnderTest)
            manager.addMessage(validForOther)
            manager.addMessage(expiredForOther)

            var continued: [InAppContentBlockResponse]?
            manager.filterCarouselData(
                placeholder: "ph_under_test",
                continueCallback: { continued = $0 },
                expiredCompletion: { }
            )

            expect(continued?.count).to(equal(1))
            expect(continued?.first?.id).to(equal(validForUnderTest.id))
        }
    }
}
