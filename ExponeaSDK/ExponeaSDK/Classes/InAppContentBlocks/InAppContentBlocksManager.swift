//
//  InAppContentBlocksManager.swift
//  ExponeaSDK
//
//  Created by Ankmara on 17.05.2023.
//  Copyright © 2023 Exponea. All rights reserved.
//

import Foundation
import AppTrackingTransparency
import WebKit
#if canImport(ExponeaSDKShared)
import ExponeaSDKShared
#endif

final class InAppContentBlocksManager: NSObject {

    // MARK: - Properties
    static let manager = InAppContentBlocksManager()
    @Atomic var inAppContentBlockMessages: [InAppContentBlockResponse] = []
    var refreshCallback: TypeBlock<IndexPath>?
    let urlOpener: UrlOpenerType = UrlOpener()
    let disableZoomSource: String =
    """
        var meta = document.createElement('meta');
        meta.name = 'viewport';
        meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        var head = document.getElementsByTagName('head')[0];
        head.appendChild(meta);
    """
    let blockRules =
    """
        [{
            "trigger": {
                "url-filter": ".*",
                "resource-type": []
            },
            "action": {
                "type": "block"
            }
        }]
    """
    var contentRuleList: WKContentRuleList?

    private var isStaticUpdating = false
    private var isUpdating = false
    private var isLoadUpdating = false
    private var isCarouselLoading = false
    private let carouselValidationQueue = DispatchQueue(
        label: "com.exponea.ExponeaSDK.inappcontentblocks.carouselvalidation",
        qos: .utility,
        attributes: .concurrent
    )
    private let maxImageValidationConcurrency = 4
    private let maxCarouselValidationConcurrency = 2
    private let imageValidationTimeout: TimeInterval = 10
    // Per-placeholder validation tokens. Multiple `CarouselInAppContentBlockView`s may load in parallel,
    // so cancellation must be scoped per placeholder to avoid concurrent carousels invalidating each other.
    @Atomic var carouselValidationTokens: [String: UUID] = [:]
    // Per-placeholder in-flight dedup state. Without this, two back-to-back reload()
    // calls for the same placeholder would issue two identical personalization POSTs.
    // Second and later callers attach as waiters on the first in-flight fetch rather
    // than issue a duplicate provider call. The record's `validationToken` anchors
    // the completion to THIS fetch so a late-arriving callback from a superseded run
    // cannot consume a newer run's waiters.
    @Atomic var carouselInFlightFetches: [String: CarouselInFlightFetch] = [:]
    @Atomic private var queue: [QueueData] = []
    @Atomic private var loadQueue: [QueueLoadData] = []
    private var staticQueue: [StaticQueueData] = []
    @Atomic private var carouselQueue: [String] = []
    @Atomic var imageValidationStates: [String: ImageValidationState] = [:]

    private var newUsedInAppContentBlocks: UsedInAppContentBlocks? {
        willSet {
            guard let newValue, let placeholder = newValue.placeholderData else { return }
            if placeholder.content == nil, newValue.height == 0 {
                loadContentForPlacehoder(newValue: newValue, message: placeholder)
            } else if let html = placeholder.content?.html, newValue.height == 0 {
                calculator = .init()
                calculator.heightUpdate = { [weak self] height in
                    guard let self else { return }
                    self.calculateStaticData(height: height, newValue: newValue, placeholder: placeholder)
                }
                calculator.loadHtml(placedholderId: newValue.messageId, html: html)
            }
        }
    }
    @Atomic private var usedInAppContentBlocks: [String: [UsedInAppContentBlocks]] = [:]
    private let sessionStart = Date()
    private let provider: InAppContentBlocksDataProviderType

    // MARK: - Init
    override init() {
        self.provider = InAppContentBlocksDataProvider()
        super.init()
        
        _usedInAppContentBlocks.changeValue(with: { $0.removeAll() })

        IntegrationManager.shared.onIntegrationStoppedCallbacks.append { [weak self] in
            guard let self else { return }
            self.usedInAppContentBlocks.forEach { key, value in
                let content = self.usedInAppContentBlocks[key] ?? []
                let updatedMessages = content.map { content in
                    var copy = content
                    copy.height = 0
                    return copy
                }
                self.usedInAppContentBlocks[key] = updatedMessages
            }
            self._inAppContentBlockMessages.changeValue(with: { $0.removeAll() })
            self.usedInAppContentBlocks.removeAll()
            self._imageValidationStates.changeValue(with: { $0.removeAll() })
            self._carouselValidationTokens.changeValue(with: { $0.removeAll() })
            // Drop every in-flight dedup record — the still-outstanding provider callbacks
            // will no-op at the token-match guard, which keeps their waiters unfulfilled.
            // That is consistent with pre-fix behavior where the provider short-circuits
            // on `IntegrationManager.shared.isStopped` before invoking the caller's
            // completion.
            self._carouselInFlightFetches.changeValue(with: { $0.removeAll() })
        }
    }

    internal func addMessage(_ message: InAppContentBlockResponse) {
        _inAppContentBlockMessages.changeValue { $0.append(message) }
    }

    func initBlocker() {
        onMain {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ContentBlockingRules",
                encodedContentRuleList: self.blockRules
            ) { contentRuleList, error in
                guard error == nil else { return }
                self.contentRuleList = contentRuleList
            }
        }
    }

    private var key: String = "key_WKWebView"
    private var web: WKWebView {
        get {
            objc_getAssociatedObject(self, &key) as! WKWebView
        }
        set {
            let userScript: WKUserScript = .init(source: disableZoomSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            let newWebview = newValue
            newValue.frame = .init(x: 0, y: 0, width: UIScreen.main.bounds.size.width, height: 0)
            newWebview.scrollView.showsVerticalScrollIndicator = false
            newWebview.scrollView.bounces = false
            newWebview.backgroundColor = .clear
            newWebview.isOpaque = false
            let configuration = newWebview.configuration
            configuration.userContentController.addUserScript(userScript)
            if let contentRuleList {
                configuration.userContentController.add(contentRuleList)
            }
            objc_setAssociatedObject(self, &key, newWebview, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private var calculatorKey: String = "key_calculator"
    var calculator: WKWebViewHeightCalculator {
        get {
            objc_getAssociatedObject(self, &calculatorKey) as! WKWebViewHeightCalculator
        }
        set {
            objc_setAssociatedObject(self, &calculatorKey, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

struct WKWebViewData {
    let height: CGFloat
    let tag: Int
}

internal enum ImageValidationState {
    case pending
    case valid
    case corrupted
}

/// Per-placeholder in-flight carousel fetch record.
///
/// Anchors the result of an in-flight `loadMessagesForCarousel` call to the `validationToken`
/// captured at fetch-registration time. Additional callers for the same placeholder append
/// themselves to `waiters` rather than issuing a duplicate provider call. When the fetch
/// completes, the callback claims this record only if its `validationToken` still matches —
/// a newer fetch that rotated the token mid-flight will have registered its own record and
/// must not be silently consumed by a stale callback.
///
/// `fileprivate`-equivalent via the `internal` struct scope paired with the consumer being
/// the owning manager file. Not part of the public SDK surface.
internal struct CarouselInFlightFetch {
    let validationToken: UUID
    var waiters: [(initial: EmptyBlock?, completion: EmptyBlock?)]
}

// MARK: InAppContentBlocksManagerType
extension InAppContentBlocksManager: InAppContentBlocksManagerType, WKNavigationDelegate {    
    func hasHtmlImages(html: String) -> Bool {
        return hasHtmlImages(html: html, maxConcurrentDownloads: maxImageValidationConcurrency)
    }

    private func hasHtmlImages(
        html: String,
        maxConcurrentDownloads: Int,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let collectImages = HtmlNormalizer(html).collectImages()
        guard !collectImages.isEmpty else { return true }
        let imageUrls = collectImages.compactMap { URL(string: $0) }
        guard !imageUrls.isEmpty else {
            Exponea.logger.log(.warning, message: "No correct images inside \(html)")
            return false
        }
        if shouldCancel() {
            return false
        }
        // Try the on-disk image cache before hitting the network.
        //
        // On the primary carousel path, `HtmlNormalizer.asBase64Image` (invoked during
        // `loadMessagesForCarousel`'s offline-bake step) has already downloaded every image
        // URL and written it to `InAppMessagesCache`. Re-fetching those same URLs here over
        // an ephemeral `URLSession` with `.reloadIgnoringLocalCacheData` would add ~hundreds
        // of ms per carousel cold-paint for no verdict benefit. A decoded `UIImage` from
        // the cache is sufficient proof the message has at least one valid image, which is
        // all `hasHtmlImages` promises.
        //
        // URLs whose cache entry is missing or whose cached bytes fail to decode fall
        // through to the existing network validation path, preserving behaviour for
        // non-carousel call sites and for cache misses/corruption on the carousel path.
        let imageCache: InAppMessagesCacheType = InAppMessagesCache()
        var urlsNeedingNetwork: [URL] = []
        urlsNeedingNetwork.reserveCapacity(imageUrls.count)
        for url in imageUrls {
            if shouldCancel() {
                return false
            }
            if let data = imageCache.getImageData(at: url.absoluteString),
               UIImage(data: data) != nil {
                return true
            }
            urlsNeedingNetwork.append(url)
        }
        let timeout = imageValidationTimeout
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: sessionConfig)
        let stateLock = NSLock()
        var isAnyCorrectImage = false
        let maxConcurrent = max(1, min(maxConcurrentDownloads, urlsNeedingNetwork.count))
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = maxConcurrent
        operationQueue.qualityOfService = .utility
        for url in urlsNeedingNetwork {
            operationQueue.addOperation {
                stateLock.lock()
                let alreadyFound = isAnyCorrectImage
                stateLock.unlock()
                if shouldCancel() || alreadyFound {
                    return
                }
                let request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: timeout
                )
                let taskDone = DispatchSemaphore(value: 0)
                let task = session.dataTask(with: request) { data, _, _ in
                    defer { taskDone.signal() }
                    guard !shouldCancel() else { return }
                    autoreleasepool {
                        if let data, UIImage(data: data) != nil {
                            stateLock.lock()
                            let wasFirst = !isAnyCorrectImage
                            isAnyCorrectImage = true
                            stateLock.unlock()
                            if wasFirst {
                                // One valid image is enough — tear down sibling downloads
                                // eagerly rather than waiting for each task's `timeout + 1`
                                // to elapse. Safe to call once; subsequent completions fall
                                // through `wasFirst == false`. The trailing
                                // `session.invalidateAndCancel()` after the wait loop
                                // remains as a no-op safety net for the no-success path.
                                session.invalidateAndCancel()
                            }
                        }
                    }
                }
                task.resume()
                if taskDone.wait(timeout: .now() + timeout + 1) == .timedOut {
                    task.cancel()
                }
            }
        }
        operationQueue.waitUntilAllOperationsAreFinished()
        session.invalidateAndCancel()
        if shouldCancel() {
            return false
        }
        if !isAnyCorrectImage {
            Exponea.logger.log(.warning, message: "No correct images inside \(html)")
        }
        return isAnyCorrectImage
    }

    func getUsedInAppContentBlocks(placeholder: String, indexPath: IndexPath) -> UsedInAppContentBlocks? {
        return usedInAppContentBlocks[placeholder]?.first(where: { $0.indexPath == indexPath && $0.isActive })
    }

    func anonymize() {
        usedInAppContentBlocks.removeAll()
        inAppContentBlockMessages.removeAll()
        _imageValidationStates.changeValue(with: { $0.removeAll() })
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let webviewtag = webView.tag
        var selectedUsed: UsedInAppContentBlocks?
        for message in inAppContentBlockMessages where message.tags?.contains(webviewtag) == true {
            for placeholder in message.placeholders {
                if let used = usedInAppContentBlocks[placeholder], let selected = used.first(where: { $0.isActive && $0.messageId == message.id }) {
                    selectedUsed = selected
                    break
                }
            }
        }
        guard let selectedUsed, let inAppContentBlockResponse = inAppContentBlockMessages.first(where: { $0.id == selectedUsed.messageId }) else {
            decisionHandler(.cancel)
            return
        }
        let webAction: WebActionManager = .init { _ in
            self.updateInteractedState(for: selectedUsed.messageId)
            Exponea.shared.trackInAppContentBlockClose(
                placeholderId: selectedUsed.placeholder,
                message: inAppContentBlockResponse
            )
            self.refreshCallback?(selectedUsed.indexPath)
        } onActionCallback: { action in
            let inAppCbAction = InAppContentBlockAction(
                name: action.buttonText,
                url: action.actionUrl,
                type: self.determineActionType(action: action)
            )
            self.updateInteractedState(for: selectedUsed.messageId)
            Exponea.shared.trackInAppContentBlockClick(
                placeholderId: selectedUsed.placeholder,
                action: inAppCbAction,
                message: inAppContentBlockResponse
            )
            self.invokeActionInternally(inAppCbAction)
            self.refreshCallback?(selectedUsed.indexPath)
        } onErrorCallback: { error in
            let errorMessage = "WebActionManager error \(error.localizedDescription)"
            Exponea.logger.log(.error, message: errorMessage)
            Exponea.shared.trackInAppContentBlockError(
                placeholderId: selectedUsed.placeholder,
                message: inAppContentBlockResponse,
                errorMessage: errorMessage
            )
        }
        webAction.htmlPayload = inAppContentBlockResponse.normalizedResult ?? inAppContentBlockResponse.personalizedMessage?.htmlPayload
        let handled = webAction.handleActionClick(navigationAction.request.url)
        if handled {
            Exponea.logger.log(.verbose, message: "[HTML] Action \(navigationAction.request.url?.absoluteString ?? "Invalid") has been handled")
            decisionHandler(.cancel)
        } else {
            Exponea.logger.log(.verbose, message: "[HTML] Action \(navigationAction.request.url?.absoluteString ?? "Invalid") has not been handled, continue")
            decisionHandler(.allow)
        }
    }
    
    private func invokeActionInternally(_ action: InAppContentBlockAction) {
        switch action.type {
        case .browser:
            openBrowserAction(action)
        case .deeplink:
            openDeeplinkAction(action)
        default:
            Exponea.logger.log(.warning, message: "No AppInbox action for type \(action.type)")
        }
    }

    func openBrowserAction(_ action: InAppContentBlockAction) {
        guard let buttonLink = action.url else {
            Exponea.logger.log(.error, message: "AppInbox action \"\(action.name ?? "<nil>")\" contains invalid browser link \(action.url ?? "<nil>")")
            return
        }
        urlOpener.openBrowserLink(buttonLink)
    }

    func openDeeplinkAction(_ action: InAppContentBlockAction) {
        guard let buttonLink = action.url else {
            Exponea.logger.log(.error, message: "AppInbox action \"\(action.name ?? "<nil>")\" contains invalid universal link \(action.url ?? "<nil>")")
            return
        }
        urlOpener.openDeeplink(buttonLink)
    }

    private func determineActionType(action: ActionInfo) -> InAppContentBlockActionType {
        switch action.actionType {
        case .browser:
            return .browser
        case .deeplink:
            return .deeplink
        case .close:
            return .close
        }
    }

    private func parseData(placeholderId: String, data: ResponseData<PersonalizedInAppContentBlockResponseData>, tags: Set<Int>, completion: EmptyBlock?) {
        ensureBackground {
            let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data.compactMap { response in
                var newInAppContentBlocks = response
                let normalizeConf = HtmlNormalizerConfig(
                    makeResourcesOffline: true,
                    ensureCloseButton: false
                )
                let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                newInAppContentBlocks.htmlPayload = normalizedPayload
                let isCorruptedImage = !self.hasHtmlImages(html: response.content?.html ?? "")
                newInAppContentBlocks.isCorruptedImage = isCorruptedImage
                return newInAppContentBlocks
            } ?? []
            var updatedPlaceholders: [InAppContentBlockResponse] = self.inAppContentBlockMessages
            var updatedContentBlocksForTelemetry: [InAppContentBlockResponse] = []
            for (index, inAppContentBlocks) in updatedPlaceholders.enumerated() {
                if var personalized = personalizedWithPayload.first(where: { $0.id == inAppContentBlocks.id }) {
                    personalized.ttlSeen = Date()
                    updatedPlaceholders[index].personalizedMessage = personalized
                    updatedContentBlocksForTelemetry.append(updatedPlaceholders[index])
                }
            }
            self.inAppContentBlockMessages = updatedPlaceholders
            self.trackTelemetryForFetch(.contentBlockPersonalisedFetch, updatedContentBlocksForTelemetry)
            onMain {
                completion?()
            }
        }
    }
    
    private func trackTelemetryForFetch(_ fetchType: TelemetryEventType, _ info: [InAppContentBlockResponse]) {
        Exponea.shared.telemetryManager?.report(
            eventWithType: fetchType,
            properties: [
                "count": String(info.count),
                "data": TelemetryUtility.toJson(info.map { [
                    "messageId": $0.id,
                    "placeholders": TelemetryUtility.toJson($0.placeholders),
                    "type": ($0.content == nil ? "personal" : "static")
                ] })
            ]
        )
    }

    func prefetchPlaceholdersWithIds(input: [InAppContentBlockResponse], ids: [String]) -> [InAppContentBlockResponse] {
        input.filter { inAppContentBlocks in
            !inAppContentBlocks.placeholders.filter { placeholder in
                ids.contains(placeholder)
            }.isEmpty
        }
    }

    func prefetchPlaceholdersWithIds(ids: [String]) {
        Exponea.logger.log(.verbose, message: "In-app Content Blocks prefetch starts.")
        guard let customerIds = try? DatabaseManager().currentCustomer.ids, !ids.isEmpty else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks prefetch starts failed due to customer ids or ids are empty")
            return
        }
        Exponea.logger.log(.verbose, message: "In-app Content Blocks prefetch ids \(ids)")
        provider.loadPersonalizedInAppContentBlocks(
            data: PersonalizedInAppContentBlockResponseData.self,
            customerIds: customerIds,
            inAppContentBlocksIds: prefetchPlaceholdersWithIds(input: inAppContentBlockMessages, ids: ids).map { $0.id }
        ) { [weak self] messages in
            guard let self else { return }
            ensureBackground {
                let prefetchedMessagesDescriptions = (messages.data?.data ?? []).map { $0.describeDetailed() }
                Exponea.logger.log(.verbose, message: "In-app Content Blocks downloaded prefetched messages \(prefetchedMessagesDescriptions)")
                let personalizedWithPayload: [PersonalizedInAppContentBlockResponse]? = messages.data?.data.filter { $0.status == .ok }.compactMap { response in
                    var newInAppContentBlocks = response
                    let normalizeConf = HtmlNormalizerConfig(
                        makeResourcesOffline: false,
                        ensureCloseButton: false
                    )
                    let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                    newInAppContentBlocks.htmlPayload = normalizedPayload
                    let isCorruptedImage = !self.hasHtmlImages(html: response.content?.html ?? "")
                    newInAppContentBlocks.isCorruptedImage = isCorruptedImage
                    return newInAppContentBlocks
                }
                var updatedPlaceholders: [InAppContentBlockResponse] = self.inAppContentBlockMessages
                var updatedContentBlocksForTelemetry: [InAppContentBlockResponse] = []
                for (index, inAppContentBlocks) in updatedPlaceholders.enumerated() {
                    if var personalized = personalizedWithPayload?.first(where: { $0.id == inAppContentBlocks.id }) {
                        personalized.ttlSeen = Date()
                        updatedPlaceholders[index].personalizedMessage = personalized
                        updatedContentBlocksForTelemetry.append(updatedPlaceholders[index])
                    }
                }
                self.inAppContentBlockMessages = updatedPlaceholders
                self.trackTelemetryForFetch(.contentBlockPersonalisedFetch, updatedContentBlocksForTelemetry)
            }
        }
    }

    func getFilteredMessage(message: InAppContentBlockResponse) -> Bool {        
        let displayState = getDisplayState(of: message.id)
        switch message.frequency {
        case .oncePerVisit:
            let shouldDisplay = displayState.displayed == nil
            if !shouldDisplay {
                Exponea.logger.log(.verbose, message: "In-app Content Blocks '\(message.name)' already displayed.")
            }
            return shouldDisplay
        case .onlyOnce:
            let shouldDisplay = displayState.displayed ?? Date(timeIntervalSince1970: 0) < sessionStart
            if !shouldDisplay {
                Exponea.logger.log(.verbose, message: "In-app Content Blocks '\(message.name)' already displayed this session.")
            }
            return shouldDisplay
        case .untilVisitorInteracts:
            let shouldDisplay = displayState.interacted == nil
            Exponea.logger.log(.verbose, message: "shouldDisplay \(shouldDisplay) for id \(message.id)")
            if !shouldDisplay {
                Exponea.logger.log(.verbose, message: "In-app Content Blocks '\(message.name)' already interacted with.")
            }
            return shouldDisplay
        case .always:
            return true
        case .none:
            Exponea.logger.log(.warning, message: "Unknown inAppContentBlocks message frequency.")
            return true
        }
    }

    func filterPriority(input: [InAppContentBlockResponse]) -> [Int: [InAppContentBlockResponse]] {
        var toReturn: [Int: [InAppContentBlockResponse]] = [:]
        for inAppContentBlocks in input {
            let prio = inAppContentBlocks.loadPriority ?? 0
            if toReturn[prio] != nil {
                toReturn[prio]?.append(inAppContentBlocks)
            } else {
                toReturn[prio] = [inAppContentBlocks]
            }
        }
        return toReturn
    }

    private func markAsActive(message: InAppContentBlockResponse, indexPath: IndexPath, placeholderId: String) {
        let usedMessages = usedInAppContentBlocks[placeholderId] ?? []
        var blocksToReturn: [UsedInAppContentBlocks] = []
        for msg in usedMessages {
            var value = msg
            value.isActive = value.messageId == message.id
            if value.isActive {
                value.indexPath = indexPath
            }
            blocksToReturn.append(value)
        }
        Exponea.logger.log(.verbose, message: "In-app Content Blocks markAsActive indexPath: \(indexPath), placeholderId: \(placeholderId).")
        _usedInAppContentBlocks.changeValue(with: { $0[placeholderId] = blocksToReturn })
        Exponea.logger.log(.verbose, message: "In-app Content Blocks updated \(usedInAppContentBlocks.mapValues { $0.map { $0.describeDetailed() } })")
    }

    private func markAsInactive(indexPath: IndexPath, placeholderId: String) {
        let usedMessages = usedInAppContentBlocks[placeholderId] ?? []
        var blocksToReturn: [UsedInAppContentBlocks] = []
        for msg in usedMessages {
            var value = msg
            if value.indexPath == indexPath {
                value.isActive = false
            }
            blocksToReturn.append(value)
        }
        Exponea.logger.log(.verbose, message: "In-app Content Blocks markAsInactive indexPath: \(indexPath), placeholderId: \(placeholderId).")
        _usedInAppContentBlocks.changeValue(with: { $0[placeholderId] = blocksToReturn })
        Exponea.logger.log(.verbose, message: "In-app Content Blocks updated \(usedInAppContentBlocks.mapValues { $0.map { $0.describeDetailed() } })")
    }

    func prepareInAppContentBlockView(placeholderId: String, indexPath: IndexPath) -> UIView {
        guard !IntegrationManager.shared.isStopped else {
            Exponea.logger.log(.verbose, message: "In-app content blocks fetch failed: SDK is stopping")
            return .init()
        }
        let messagesToUse = inAppContentBlockMessages.filter { $0.placeholders.contains(placeholderId) }
        let messagesNeedToRefresh = messagesToUse.filter { $0.personalizedMessage == nil && $0.content?.html == nil }
        let expiredMessages = messagesToUse.filter { inAppContentBlocks in
            if let ttlSeen = inAppContentBlocks.personalizedMessage?.ttlSeen,
               let ttl = inAppContentBlocks.personalizedMessage?.ttlSeconds,
               inAppContentBlocks.content == nil {
                return Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
            }
            return false
        }
        guard messagesNeedToRefresh.isEmpty && expiredMessages.isEmpty else {
            Exponea.logger.log(.verbose, message: "Loading content for In-app Content Block with placeholder: \(placeholderId) and indxPath \(indexPath)")
            markAsInactive(indexPath: indexPath, placeholderId: placeholderId)
            loadContent(indexPath: indexPath, placeholder: placeholderId, expired: expiredMessages)
            return returnEmptyView(tag: Int.random(in: 0..<99999999))
        }
        let contentBlocksForId = usedInAppContentBlocks[placeholderId] ?? []
        let messagesForThisIndexPath = contentBlocksForId.filter { $0.indexPath == indexPath }
        var messagesToFilter: [InAppContentBlockResponse] = []
        for message in inAppContentBlockMessages where contentBlocksForId.contains(where: { $0.messageId == message.id }) {
            messagesToFilter.append(message)
        }
        guard let message = filterPersonalizedMessages(input: messagesToFilter) else {
            Exponea.logger.log(.verbose, message: "No more In-app Content Block messages for indexPath  \(indexPath)")
            markAsInactive(indexPath: indexPath, placeholderId: placeholderId)
            return returnEmptyView(tag: Int.random(in: 0..<99999999))
        }
        Exponea.logger.log(.verbose, message: "Filtered In-app Content Block \(message.describe())")
        markAsActive(message: message, indexPath: indexPath, placeholderId: placeholderId)
        let tag = createUniqueTag(placeholder: message)
        let indexOfPlaceholder: Int = inAppContentBlockMessages.firstIndex(where: { $0.indexPath == message.indexPath }) ?? 0
        updateDisplayedState(for: message.id)

        web = .init()
        web.tag = tag
        web.navigationDelegate = self

        if let html = message.content?.html, !html.isEmpty {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Block prepareInAppContentBlockView for \(message.describe())"
            )
            if inAppContentBlockMessages[indexOfPlaceholder].normalizedResult == nil {
                let normalizeConf = HtmlNormalizerConfig(
                    makeResourcesOffline: true,
                    ensureCloseButton: false
                )
                Exponea.logger.log(.verbose, message: "In-app Content Block prepareInAppContentBlockView normalizeConf \(normalizeConf)")
                let normalizedPayload = HtmlNormalizer(html).normalize(normalizeConf)
                Exponea.logger.log(
                    .verbose,
                    message: "In-app Content Block prepareInAppContentBlockView normalizedPayload is valid: \(normalizedPayload.valid)"
                )
                inAppContentBlockMessages[indexOfPlaceholder].normalizedResult = normalizedPayload
            }
            let finalHTML = inAppContentBlockMessages[indexOfPlaceholder].normalizedResult?.html ?? html
            if inAppContentBlockMessages[indexOfPlaceholder].personalizedMessage?.ttlSeen == nil {
                _inAppContentBlockMessages.changeValue(with: { $0[indexOfPlaceholder].personalizedMessage?.ttlSeen = Date() })
            }
            web.loadHTMLString(finalHTML, baseURL: nil)
            return web
        } else if let personalized = message.personalizedMessage, let payloadData = personalized.htmlPayload?.html?.data(using: .utf8), !payloadData.isEmpty {
            if inAppContentBlockMessages[indexOfPlaceholder].personalizedMessage?.ttlSeen == nil {
                _inAppContentBlockMessages.changeValue(with: { $0[indexOfPlaceholder].personalizedMessage?.ttlSeen = Date() })
            }
            if let html = personalized.htmlPayload?.html, !html.isEmpty {
                web.loadHTMLString(html, baseURL: nil)
                return web
            } else {
                return returnEmptyView(tag: tag)
            }
        } else {
            return returnEmptyView(tag: tag)
        }
    }

    func filterCarouselData(placeholder: String, continueCallback: TypeBlock<[InAppContentBlockResponse]>?, expiredCompletion: EmptyBlock?) {
        let placehodlersToUse = inAppContentBlockMessages.filter { !$0.placeholders.filter { $0 == placeholder }.isEmpty }
        let placeholdersNeedToRefresh = placehodlersToUse.filter { $0.personalizedMessage == nil && $0.content?.html == nil }
        // Scope expiration to the placeholder being loaded. `loadMessagesForCarousel`
        // only re-fetches `idsForDownload = messages.filter { $0.placeholders.contains(placeholder) }`,
        // so an unrelated placeholder's expired messages can never be refreshed via this
        // path. Including them here used to cause a permanent deadlock: e.g. when the
        // app comes back from a long background (phone locked > TTL), every unrelated
        // static-CB message is past its `ttlSeen + ttlSeconds`, the guard below
        // forwards to `expiredCompletion?()` which re-runs `loadMessagesForCarousel`,
        // which only refreshes the carousel's own messages, which leaves the unrelated
        // ones expired — and the loop continues forever, leaving the carousel blank.
        // The static-CB sibling `prepareInAppContentBlocksStaticView` already scopes
        // its expiration check to `placehodlersToUse`; this matches it.
        let expiredMessages = placehodlersToUse.filter { inAppContentBlocks in
            if let ttlSeen = inAppContentBlocks.personalizedMessage?.ttlSeen,
               let ttl = inAppContentBlocks.personalizedMessage?.ttlSeconds {
                return Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
            }
            return false
        }
        let notFoundPersonalizedMessages = inAppContentBlockMessages.filter { inAppContentBlocks in
            inAppContentBlocks.personalizedMessage == nil
        }
        let expiredMessagesDescriptions = expiredMessages.map { $0.describe() }
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks prepareInAppContentBlocksStaticView expiredMessages \(expiredMessagesDescriptions)."
        )
        if expiredMessages.isEmpty && !notFoundPersonalizedMessages.isEmpty && placehodlersToUse.isEmpty {
            continueCallback?([])
            return
        }
        guard placeholdersNeedToRefresh.isEmpty && expiredMessages.isEmpty else {
            expiredCompletion?()
            return
        }
        let filtered = placehodlersToUse.filter { inAppContentBlocksPlaceholder in
            let validationState = self.imageValidationStates[inAppContentBlocksPlaceholder.id]
            if validationState == .pending || validationState == .corrupted {
                return false
            }
            if inAppContentBlocksPlaceholder.personalizedMessage?.status == .ok && inAppContentBlocksPlaceholder.personalizedMessage?.isCorruptedImage == false {
                return self.getFilteredMessage(message: inAppContentBlocksPlaceholder)
            } else {
                return false
            }
        }
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks filtering result: \(filtered.map { $0.describe() })"
        )
        guard !filtered.isEmpty else {
            expiredCompletion?()
            return
        }
        continueCallback?(filtered)
    }

    func prepareInAppContentBlocksStaticView(
        placeholderId: String,
        makeResourcesOffline: Bool = true
    ) -> StaticReturnData {
        let placehodlersToUse = inAppContentBlockMessages.filter { !$0.placeholders.filter { $0 == placeholderId }.isEmpty }
        let placeholdersNeedToRefresh = placehodlersToUse.filter { $0.personalizedMessage == nil && $0.content?.html == nil }
        let expiredMessages = placehodlersToUse.filter { inAppContentBlocks in
            if let ttlSeen = inAppContentBlocks.personalizedMessage?.ttlSeen,
               let ttl = inAppContentBlocks.personalizedMessage?.ttlSeconds,
               inAppContentBlocks.content == nil {
                return Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
            }
            return false
        }
        let expiredMessagesDescriptions = expiredMessages.map { $0.describe() }
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks prepareInAppContentBlocksStaticView expiredMessages \(expiredMessagesDescriptions)."
        )
        guard placeholdersNeedToRefresh.isEmpty && expiredMessages.isEmpty else {
            return .init(html: "", tag: 0, message: nil)
        }

        // Found message
        let candidates = placehodlersToUse.filter { $0.personalizedMessage?.status == .ok }
        guard var message = filterPersonalizedMessages(input: candidates) else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks prepareInAppContentBlocksStaticView message not found.")
            return .init(html: "", tag: 0, message: nil)
        }
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks prepareInAppContentBlocksStaticView message \(message.describe())."
        )

        // Add random for 100% unique
        let tag = createUniqueTag(placeholder: message)
        Exponea.logger.log(.verbose, message: "In-app Content Blocks prepareInAppContentBlocksStaticView tag \(tag).")

        // Update display status
        updateDisplayedState(for: message.id)
        message.tags?.insert(tag)

        // Lazy HTML normalization — normalize on demand, cache result for default (makeResourcesOffline: true) only.
        // When makeResourcesOffline is false (skipNativeRendering), always re-normalize without writing to the
        // shared cache so that the cached payload is never contaminated with a non-offline-resource version.
        if var personalized = message.personalizedMessage {
            let needsNormalization = personalized.htmlPayload?.html?.isEmpty ?? true
            if needsNormalization || !makeResourcesOffline {
                let normalizeConf = HtmlNormalizerConfig(
                    makeResourcesOffline: makeResourcesOffline,
                    ensureCloseButton: false
                )
                let normalizedPayload = HtmlNormalizer(personalized.content?.html ?? "").normalize(normalizeConf)
                personalized.htmlPayload = normalizedPayload
                message.personalizedMessage = personalized
            }
        }

        if let personalized = message.personalizedMessage, let payloadData = personalized.htmlPayload?.html?.data(using: .utf8), !payloadData.isEmpty {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks prepareInAppContentBlocksStaticView personalized \(personalized.describeDetailed())."
            )
            if let html = personalized.htmlPayload?.html, !html.isEmpty {
                _inAppContentBlockMessages.changeValue { messages in
                    guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
                    // Preserve existing ttlSeen across the full-message overwrite: the local `message`
                    // may not carry ttlSeen, so we capture it before overwriting and restore it if needed.
                    let existingTtlSeen = messages[index].personalizedMessage?.ttlSeen
                    messages[index] = message
                    if messages[index].personalizedMessage?.ttlSeen == nil {
                        messages[index].personalizedMessage?.ttlSeen = existingTtlSeen ?? Date()
                    }
                }
                return .init(html: html, tag: tag, message: message)
            }
        } else {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks prepareInAppContentBlocksStaticView static \(message.describe())."
            )
            if let html = message.content?.html, !html.isEmpty {
                _inAppContentBlockMessages.changeValue { messages in
                    guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
                    messages[index] = message
                }
                return .init(html: html, tag: tag, message: message)
            }
        }
        return .init(html: "", tag: 0, message: nil)
    }

    func loadInAppContentBlockMessages(completion: EmptyBlock?) {
        provider.getInAppContentBlocks(
            data: InAppContentBlocksDataResponse.self
        ) { [weak self] result in
            guard result.data?.success == true, let messages = result.data?.data else { return }
            ensureBackground {
                let filteredMessages: [InAppContentBlockResponse] = messages.map { message in
                    if let content = message.content?.html {
                        var msg = message
                        msg.isCorruptedImage = self?.hasHtmlImages(html: content) == false
                        return msg
                    }
                    return message
                }
                self?.inAppContentBlockMessages = filteredMessages
                let validIds = Set(filteredMessages.map { $0.id })
                self?._imageValidationStates.changeValue { states in
                    states = states.filter { validIds.contains($0.key) }
                }
                let loadedMessagesDescriptions = (result.data?.data ?? []).map { $0.describe() }
                Exponea.logger.log(
                    .verbose,
                    message: "In-app Content Blocks loadInAppContentBlockMessages done with \(loadedMessagesDescriptions)."
                )
                self?.trackTelemetryForFetch(.contentBlockInitFetch, messages)
                completion?()
            }
        }
    }
}

private extension InAppContentBlocksManager {
    func loadPersonalizedInAppContentBlocks(for placeholderId: String, tags: Set<Int>, skipLoad: Bool = false, completion: EmptyBlock?) {
        Exponea.logger.log(.verbose, message: "In-app Content Blocks loadPersonalizedInAppContentBlocks starts")
        guard !placeholderId.isEmpty, let ids = try? DatabaseManager().currentCustomer.ids else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks loadPersonalizedInAppContentBlocks failed placeholderId.isEmpty: \(placeholderId.isEmpty) and ids: \(String(describing: try? DatabaseManager().currentCustomer.ids))")
            return
        }
        DispatchQueue.global().async {
            if skipLoad {
                onMain {
                    completion?()
                }
            } else {
                self.provider.loadPersonalizedInAppContentBlocks(
                    data: PersonalizedInAppContentBlockResponseData.self,
                    customerIds: ids,
                    inAppContentBlocksIds: [placeholderId]
                ) { [weak self] data in
                    guard let self else { return }
                    let responseDescribed = """
                        {
                            data: \(String(describing: data.data?.data.map { $0.describeDetailed() })),
                            error: \(String(describing: data.error))
                        }
                        """
                    Exponea.logger.log(
                        .verbose,
                        message: "In-app Content Blocks loadPersonalizedInAppContentBlocks loaded: \(responseDescribed)"
                    )
                    self.parseData(placeholderId: placeholderId, data: data, tags: tags, completion: completion)
                }
            }
        }
    }

    internal func applyDateFilter(message: InAppContentBlockResponse) -> Bool {
        guard message.dateFilter.enabled else {
            return true
        }
        if let start = message.dateFilter.fromDate, start > Date() {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks '\(message.name)' outside of date range.")
            return false
        }
        if let end = message.dateFilter.toDate, end < Date() {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks '\(message.name)' outside of date range.")
            return false
        }
        return true
    }

    func filterPersonalizedMessages(input: [InAppContentBlockResponse]) -> InAppContentBlockResponse? {
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks filterPersonalizedMessages filtering: \(input.map { $0.describe() })"
        )
        let filtered = input
            .filter { applyDateFilter(message: $0) }
            .filter { inAppContentBlocksPlaceholder in
            if inAppContentBlocksPlaceholder.personalizedMessage?.status == .ok && inAppContentBlocksPlaceholder.personalizedMessage?.isCorruptedImage == false {
                return self.getFilteredMessage(message: inAppContentBlocksPlaceholder)
            } else {
                return false
            }
        }
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks filtering result: \(filtered.map { $0.describe() })"
        )
        guard !filtered.isEmpty else {
            return nil
        }
        let sorted = filtered.sorted { lhs, rhs in
            lhs.loadPriority ?? 0 > rhs.loadPriority ?? 0
        }
        let toReturnArray = filterPriority(input: sorted).sorted(by: { $0.key > $1.key })
        let toReturn = toReturnArray.first?.value.randomElement()
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks winner from filtering: \(String(describing: toReturn?.describe()))")
        return toReturn
    }

    func createUniqueTag(placeholder: InAppContentBlockResponse) -> Int {
        if let tags = placeholder.tags?.first {
            return tags
        }
        return Int.random(in: 0..<99999999)
    }

    func returnEmptyView(tag: Int) -> UIView {
        let view = WKWebView(frame: .zero)
        view.tag = tag
        return view
    }

    func returnEmptyStaticView(tag: Int) -> UIView {
        let view = UIView()
        view.tag = tag
        return view
    }

    func loadContent(indexPath: IndexPath, placeholder: String, expired: [InAppContentBlockResponse]) {
        guard let ids = try? DatabaseManager().currentCustomer.ids else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks loadContent - customer ids not found")
            return
        }
        if !isLoadUpdating {
            isLoadUpdating = true
            let placehodlersToUse = inAppContentBlockMessages.filter { $0.placeholders.contains(placeholder) }
            var placeholdersNeedToGetContent = placehodlersToUse.filter { $0.indexPath == nil || $0.personalizedMessage == nil && $0.content?.html == nil }
            if placeholdersNeedToGetContent.isEmpty && !expired.isEmpty {
                placeholdersNeedToGetContent = expired
            }
            Exponea.logger.log(.verbose, message: "In-app Content Blocks placeholdersNeedToGetContent count \(placeholdersNeedToGetContent.count)")
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks placeholdersNeedToGetContent \(placeholdersNeedToGetContent.map { $0.describe() })"
            )
            Exponea.logger.log(.verbose, message:
                """
                In-app Content Blocks loadContent(indexPath: IndexPath, placeholder: String, expired: [InAppContentBlockResponse])
                indexPath: \(indexPath)
                placeholder: \(placeholder)
                expired: \(expired.map { $0.describe() })
                """
            )
            guard !placeholdersNeedToGetContent.isEmpty else {
                for placeholderInLoop in placehodlersToUse {
                    let tag = createUniqueTag(placeholder: placeholderInLoop)
                    let usedInAppContentBlocksHeight = usedInAppContentBlocks[placeholder]?.first(where: { $0.messageId == placeholderInLoop.id && $0.indexPath == indexPath })?.height ?? 0
                    self.newUsedInAppContentBlocks = .init(tag: tag, indexPath: indexPath, messageId: placeholderInLoop.id, placeholder: placeholder, height: !expired.isEmpty ? 0 : usedInAppContentBlocksHeight, placeholderData: placeholderInLoop)
                }
                isLoadUpdating = false
                if !loadQueue.isEmpty {
                    let go = loadQueue.removeFirst()
                    loadContent(indexPath: go.indexPath, placeholder: go.placeholder, expired: go.expired)
                }
                return
            }
            self.provider.loadPersonalizedInAppContentBlocks(
                data: PersonalizedInAppContentBlockResponseData.self,
                customerIds: ids,
                inAppContentBlocksIds: placeholdersNeedToGetContent.map { $0.id }
            ) { [weak self] data in
                guard let self else { return }
                ensureBackground {
                    let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data.compactMap { response in
                        var newInAppContentBlocks = response
                        let normalizeConf = HtmlNormalizerConfig(
                            makeResourcesOffline: true,
                            ensureCloseButton: false
                        )
                        let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                        newInAppContentBlocks.htmlPayload = normalizedPayload
                        let isCorruptedImage = !self.hasHtmlImages(html: response.content?.html ?? "")
                        newInAppContentBlocks.isCorruptedImage = isCorruptedImage
                        return newInAppContentBlocks
                    } ?? []
                    var logDescriptions: [String] = []
                    self._inAppContentBlockMessages.changeValue { messages in
                        for (index, inAppContentBlocks) in messages.enumerated() {
                            if var personalized = personalizedWithPayload.first(where: { $0.id == inAppContentBlocks.id }) {
                                let tag = self.createUniqueTag(placeholder: inAppContentBlocks)
                                personalized.ttlSeen = Date()
                                messages[index].personalizedMessage = personalized
                                messages[index].tags?.insert(tag)
                                messages[index].indexPath = indexPath
                            }
                        }
                        logDescriptions = messages.map { $0.describe() }
                    }
                    Exponea.logger.log(
                        .verbose,
                        message: "In-app Content Blocks updatedPlaceholders \(logDescriptions)"
                    )
                    let updatedPlacehodlersToUse = self.inAppContentBlockMessages.filter { $0.placeholders.contains(placeholder) }
                    for placeholderInLoop in updatedPlacehodlersToUse {
                        let tag = self.createUniqueTag(placeholder: placeholderInLoop)
                        let usedInAppContentBlocksHeight = self.usedInAppContentBlocks[placeholder]?.first(where: { $0.messageId == placeholderInLoop.id })?.height ?? 0
                        self.newUsedInAppContentBlocks = .init(tag: tag, indexPath: indexPath, messageId: placeholderInLoop.id, placeholder: placeholder, height: !expired.isEmpty ? 0 : usedInAppContentBlocksHeight, placeholderData: placeholderInLoop)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isLoadUpdating = false
                        guard !self.loadQueue.isEmpty else { return }
                        let go = self.loadQueue.removeFirst()
                        Exponea.logger.log(
                            .verbose,
                            message: "In-app Content Blocks load content and continue with queue {indexPath:\(go.indexPath), placeholder: \(go.placeholder), expired: \(go.expired.map { $0.describe() })}"
                        )
                        self.loadContent(indexPath: go.indexPath, placeholder: go.placeholder, expired: go.expired)
                    }
                }
            }
        } else {
            Exponea.logger.log(.verbose, message:
                """
                In-app Content Blocks added to queue
                indexPath: \(indexPath)
                placeholder: \(placeholder)
                expired: \(expired.map { $0.describe() })
                """
            )
            _loadQueue.changeValue(with: { $0.append(.init(placeholder: placeholder, indexPath: indexPath, expired: expired)) })
        }
    }

    func calculateStaticData(height: CalculatorData, newValue: UsedInAppContentBlocks, placeholder: InAppContentBlockResponse) {
        let savedNewValue = newValue
        let placeholderValueFromUsedLine = savedNewValue.placeholder
        let savedInAppContentBlocksToDeactived = self.usedInAppContentBlocks[placeholderValueFromUsedLine] ?? []
        Exponea.logger.log(.verbose, message:
            """
            In-app Content Blocks savedInAppContentBlocksToDeactived
            height: \(height)
            newValue: \(newValue.describeDetailed())
            placeholder: \(placeholder.describe())
            """
        )
        guard let indexPath = placeholder.indexPath else { return }
        if savedInAppContentBlocksToDeactived.isEmpty {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks savedInAppContentBlocksToDeactived are empty. Saved usedInAppContentBlocks \(usedInAppContentBlocks.mapValues { $0.map { $0.describeDetailed() } })"
            )
            self._usedInAppContentBlocks.changeValue { store in
                let newSavedInAppContentBlocks: UsedInAppContentBlocks = .init(tag: savedNewValue.tag, indexPath: indexPath, messageId: savedNewValue.messageId, placeholder: savedNewValue.placeholder, height: height.height)
                if store[placeholderValueFromUsedLine] == nil {
                    store[placeholderValueFromUsedLine] = [newSavedInAppContentBlocks]
                } else if store[placeholderValueFromUsedLine]?.isEmpty == true {
                    store[placeholderValueFromUsedLine]?.append(newSavedInAppContentBlocks)
                }
            }
            self.continueWithQueue()
            self.calculator.heightUpdate = nil
            self.refreshCallback?(savedNewValue.indexPath)
        } else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks usedInAppContentBlocks \(usedInAppContentBlocks.mapValues { $0.map { $0.describeDetailed() } })")
            if let indexOfSavedInAppContentBlocks: Int = self.usedInAppContentBlocks[placeholderValueFromUsedLine]?.firstIndex(where: { $0.messageId == savedNewValue.messageId && $0.height == 0 }) {
                if var savedInAppContentBlocks = self.usedInAppContentBlocks[placeholderValueFromUsedLine]?[indexOfSavedInAppContentBlocks] {
                    if savedInAppContentBlocks.height == 0 {
                        savedInAppContentBlocks.height = height.height
                    }
                    self._usedInAppContentBlocks.changeValue(with: { $0[placeholderValueFromUsedLine]?.insert(savedInAppContentBlocks, at: indexOfSavedInAppContentBlocks) })
                }
            } else {
                let newSavedInAppContentBlocks: UsedInAppContentBlocks = .init(tag: savedNewValue.tag, indexPath: indexPath, messageId: savedNewValue.messageId, placeholder: savedNewValue.placeholder, height: height.height)
                self._usedInAppContentBlocks.changeValue { store in
                    store[placeholderValueFromUsedLine]?.append(newSavedInAppContentBlocks)
                }
            }
            self.continueWithQueue()
            self.calculator.heightUpdate = nil
            self.refreshCallback?(savedNewValue.indexPath)
        }
    }
}

// MARK: - Static inAppContentBlocks
extension InAppContentBlocksManager {
    private func continueWithStaticQueue() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(.main))
            if !self.staticQueue.isEmpty {
                self.processStaticBatch()
            } else {
                self.isStaticUpdating = false
            }
        }
    }

    private func scheduleBatchProcessing() {
        DispatchQueue.main.async { [weak self] in
            self?.processStaticBatch()
        }
    }

    private func processStaticBatch() {
        dispatchPrecondition(condition: .onQueue(.main))
        let batch = staticQueue
        staticQueue.removeAll()
        guard !batch.isEmpty else {
            isStaticUpdating = false
            return
        }
        guard let customerIds = try? DatabaseManager().currentCustomer.ids else {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks cant refresh static content — no customer IDs"
            )
            batch.forEach { $0.completion?(.init(html: "", tag: 0, message: nil)) }
            isStaticUpdating = false
            return
        }
        var validRequests: [StaticQueueData] = []
        for request in batch {
            if request.placeholderId.isEmpty {
                Exponea.logger.log(
                    .verbose,
                    message: "In-app Content Blocks skipping empty placeholderId in batch"
                )
                request.completion?(.init(html: "", tag: 0, message: nil))
            } else {
                validRequests.append(request)
            }
        }
        guard !validRequests.isEmpty else {
            isStaticUpdating = false
            return
        }
        let allPlaceholderIds = Set(validRequests.map { $0.placeholderId })
        let mergedIds = Array(Set(
            inAppContentBlockMessages
                .filter { !Set($0.placeholders).isDisjoint(with: allPlaceholderIds) }
                .map { $0.id }
        ))
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks batched refresh for \(allPlaceholderIds.count) placeholder(s), \(mergedIds.count) message ID(s)"
        )
        provider.loadPersonalizedInAppContentBlocks(
            data: PersonalizedInAppContentBlockResponseData.self,
            customerIds: customerIds,
            inAppContentBlocksIds: mergedIds
        ) { [weak self] data in
            guard let self else { return }
            ensureBackground {
                if let error = data.error {
                    Exponea.logger.log(
                        .error,
                        message: "In-app Content Blocks batched refresh failed: \(error.localizedDescription)"
                    )
                    for request in validRequests {
                        onMain {
                            request.completion?(.init(html: "", tag: 0, message: nil))
                        }
                    }
                    self.continueWithStaticQueue()
                    return
                }
                guard data.data != nil else {
                    Exponea.logger.log(
                        .error,
                        message: "In-app Content Blocks batched refresh failed: missing data"
                    )
                    for request in validRequests {
                        onMain {
                            request.completion?(.init(html: "", tag: 0, message: nil))
                        }
                    }
                    self.continueWithStaticQueue()
                    return
                }
                let descriptions = (data.data?.data ?? []).map { $0.describeDetailed() }
                Exponea.logger.log(
                    .verbose,
                    message: "In-app Content Blocks batched refreshStaticViewContent data: \(descriptions)"
                )
                // Static CBs skip image validation (unlike carousel) — WKWebView handles broken images
                // with fallback rendering, so corrupted-image filtering is unnecessary here.
                let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data ?? []
                var updatedContentBlocksForTelemetry: [InAppContentBlockResponse] = []
                self._inAppContentBlockMessages.changeValue { messages in
                    for (index, inAppContentBlocks) in messages.enumerated() {
                        if var personalized = personalizedWithPayload.first(where: { $0.id == inAppContentBlocks.id }) {
                            personalized.ttlSeen = Date()
                            messages[index].personalizedMessage = personalized
                            updatedContentBlocksForTelemetry.append(messages[index])
                        }
                    }
                }
                self.trackTelemetryForFetch(.contentBlockPersonalisedFetch, updatedContentBlocksForTelemetry)
                for request in validRequests {
                    let result = self.prepareInAppContentBlocksStaticView(
                        placeholderId: request.placeholderId,
                        makeResourcesOffline: request.makeResourcesOffline
                    )
                    onMain {
                        request.completion?(result)
                    }
                }
                self.continueWithStaticQueue()
            }
        }
    }

    private func continueWithCarouselQueue(dataCompletion: TypeBlock<[StaticReturnData]>?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(.main))
            self.isCarouselLoading = false
            if !self.carouselQueue.isEmpty {
                let go = self.carouselQueue.removeFirst()
                Exponea.logger.log(.verbose, message: "In-app Content Blocks carousel queue \(go)")
                self.refreshCarouselData(placeholder: go, dataCompletion: dataCompletion)
            }
        }
    }

    public func isMessageValid(message: InAppContentBlockResponse, isValidCompletion: TypeBlock<Bool>?, refreshCallback: EmptyBlock?) {
        var isMessageExpired = false
        if let ttlSeen = message.personalizedMessage?.ttlSeen,
           let ttl = message.personalizedMessage?.ttlSeconds, message.content == nil {
            isMessageExpired = Date() > ttlSeen.addingTimeInterval(TimeInterval(ttl))
        }
        let isValid = getFilteredMessage(message: message)
        // Just expired - refresh content
        if isMessageExpired && isValid {
            refreshCallback?()
        } else {
            isValidCompletion?(isValid)
        }
    }

    /// Token-anchored claim for an in-flight carousel fetch.
    ///
    /// Returns the waiters registered on the placeholder's in-flight record only when
    /// the record was registered by this fetch (i.e. its `validationToken` matches the
    /// one captured when the fetch was kicked off) and atomically removes the record.
    /// If a newer fetch has since rotated the token and installed its own record,
    /// returns nil and leaves the newer record intact — the stale callback drops its
    /// result instead of orphaning the newer run's waiters.
    ///
    /// Kept `internal` (not exposed via `InAppContentBlocksManagerType`) so tests can
    /// drive the invariant without the public SDK surface growing.
    internal func claimInFlightCarouselFetch(
        placeholder: String,
        validationToken: UUID
    ) -> [(initial: EmptyBlock?, completion: EmptyBlock?)]? {
        var claimed: [(initial: EmptyBlock?, completion: EmptyBlock?)]?
        _carouselInFlightFetches.changeValue { map in
            if let record = map[placeholder], record.validationToken == validationToken {
                claimed = record.waiters
                map.removeValue(forKey: placeholder)
            }
        }
        return claimed
    }

    /// Loads personalized messages for a carousel placeholder and validates their images.
    ///
    /// - Parameters:
    ///   - placeholder: The placeholder ID to load messages for.
    ///   - initialCompletion: Called once the first valid (non-corrupted) message is available,
    ///     or after all validations complete if none are valid. Called on a **background queue** —
    ///     callers must dispatch to main for UI work.
    ///   - completion: Called after all image validations finish. Called on a **background queue** —
    ///     callers must dispatch to main for UI work.
    func loadMessagesForCarousel(
        placeholder: String,
        initialCompletion: EmptyBlock?,
        completion: EmptyBlock?
    ) {
        guard !placeholder.isEmpty, let ids = try? DatabaseManager().currentCustomer.ids else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks Carousel cant refresh placeholderId: \(placeholder), ids: \(String(describing: try? DatabaseManager().currentCustomer.ids))")
            ensureBackground {
                initialCompletion?()
                completion?()
            }
            return
        }

        // Dedup gate: if this placeholder already has an in-flight fetch, attach as a
        // waiter and return. The in-flight fetch's `validationToken` remains the active
        // one — we deliberately do NOT rotate it, so the currently-running image
        // validation (which uses that token as its cancellation key) keeps running
        // for the benefit of every waiter. Two back-to-back `reload()` calls now share
        // one provider call, one HTML-normalization pass, and one image-validation
        // pass (fan-out happens via the `broadcastInitial` / `broadcastCompletion`
        // wrappers below).
        var alreadyInFlight = false
        _carouselInFlightFetches.changeValue { map in
            if map[placeholder] != nil {
                map[placeholder]?.waiters.append((initialCompletion, completion))
                alreadyInFlight = true
            }
        }
        if alreadyInFlight { return }

        let validationToken = UUID()
        _carouselValidationTokens.changeValue { tokens in
            tokens[placeholder] = validationToken
        }
        _carouselInFlightFetches.changeValue { map in
            map[placeholder] = CarouselInFlightFetch(
                validationToken: validationToken,
                waiters: [(initialCompletion, completion)]
            )
        }

        let idsForDownload = inAppContentBlockMessages.filter { $0.placeholders.contains(placeholder) }.map { $0.id }
        provider.loadPersonalizedInAppContentBlocks(
            data: PersonalizedInAppContentBlockResponseData.self,
            customerIds: ids,
            inAppContentBlocksIds: idsForDownload
        ) { [weak self] data in
            guard let self else { return }

            guard let waiters = self.claimInFlightCarouselFetch(
                placeholder: placeholder,
                validationToken: validationToken
            ) else {
                Exponea.logger.log(
                    .verbose,
                    message: "In-app Content Blocks Carousel: dropping stale personalized fetch result for placeholder \(placeholder) — token rotated during flight"
                )
                return
            }

            ensureBackground {
                let refreshStaticViewContentDescriptions = (data.data?.data ?? []).map { $0.describeDetailed() }
                Exponea.logger.log(.verbose, message: "In-app Content Blocks refreshStaticViewContent data: \(refreshStaticViewContentDescriptions)")
                let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data.compactMap { response in
                    var newInAppContentBlocks = response
                    let normalizeConf = HtmlNormalizerConfig(
                        makeResourcesOffline: true,
                        ensureCloseButton: false
                    )
                    let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                    newInAppContentBlocks.htmlPayload = normalizedPayload
                    return newInAppContentBlocks
                } ?? []
                self._inAppContentBlockMessages.changeValue { messages in
                    for (index, inAppContentBlocks) in messages.enumerated() {
                        if var personalized = personalizedWithPayload.first(where: { $0.id == inAppContentBlocks.id }) {
                            personalized.ttlSeen = Date()
                            messages[index].personalizedMessage = personalized
                        }
                    }
                }
                // Fan-out: broadcast the single shared validation pass to every waiter.
                // `startCarouselImageValidation` internally one-shots its `initialCompletion`
                // via the `initialSent` atomic, so these wrappers fire each waiter's
                // `initial` exactly once (matching the per-waiter pre-dedup contract)
                // and each waiter's `completion` exactly once.
                let broadcastInitial: EmptyBlock = {
                    for waiter in waiters { waiter.initial?() }
                }
                let broadcastCompletion: EmptyBlock = {
                    for waiter in waiters { waiter.completion?() }
                }
                self.startCarouselImageValidation(
                    placeholder: placeholder,
                    responses: personalizedWithPayload,
                    validationToken: validationToken,
                    initialCompletion: broadcastInitial,
                    completion: broadcastCompletion
                )
            }
        }
    }

    private func startCarouselImageValidation(
        placeholder: String,
        responses: [PersonalizedInAppContentBlockResponse],
        validationToken: UUID,
        initialCompletion: EmptyBlock?,
        completion: EmptyBlock?
    ) {
        let candidates = responses.filter { $0.status == .ok }
        guard !candidates.isEmpty else {
            initialCompletion?()
            completion?()
            return
        }
        let priorityById = Dictionary(
            uniqueKeysWithValues: inAppContentBlockMessages.map { ($0.id, $0.loadPriority ?? 0) }
        )
        let sortedCandidates = candidates.sorted { lhs, rhs in
            let lhsPriority = priorityById[lhs.id] ?? 0
            let rhsPriority = priorityById[rhs.id] ?? 0
            if lhsPriority == rhsPriority {
                return lhs.id < rhs.id
            }
            return lhsPriority > rhsPriority
        }
        let semaphore = DispatchSemaphore(value: maxCarouselValidationConcurrency)
        let group = DispatchGroup()
        let initialSent = Atomic(wrappedValue: false)
        // Token-based cancellation scoped to the reloading placeholder so that parallel carousels
        // for different placeholders do not cancel each other. `shouldCancel` only instructs workers
        // to skip the expensive image download — completion callbacks still fire so the UI side can
        // make its own decision (it has its own `reloadToken` guard).
        let shouldCancel: () -> Bool = { [weak self] in
            guard let self else { return true }
            return self.carouselValidationTokens[placeholder] != validationToken
        }
        // Stale write protection: only persist state transitions while this run is still current.
        let writeStateIfCurrent: (String, ImageValidationState) -> Void = { [weak self] messageId, state in
            guard let self else { return }
            self._imageValidationStates.changeValue { states in
                guard self.carouselValidationTokens[placeholder] == validationToken else { return }
                states[messageId] = state
            }
        }
        for response in sortedCandidates {
            if shouldCancel() {
                break
            }
            writeStateIfCurrent(response.id, .pending)
            group.enter()
            carouselValidationQueue.async { [weak self] in
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }
                guard let self else { return }
                if shouldCancel() {
                    return
                }
                let isCorrupted = !self.hasHtmlImages(
                    html: response.content?.html ?? "",
                    maxConcurrentDownloads: self.maxImageValidationConcurrency,
                    shouldCancel: shouldCancel
                )
                if shouldCancel() {
                    return
                }
                self.updateImageValidationState(
                    messageId: response.id,
                    placeholder: placeholder,
                    validationToken: validationToken,
                    isCorrupted: isCorrupted
                )
                if !isCorrupted {
                    var shouldCall = false
                    initialSent.changeValue { value in
                        if !value {
                            value = true
                            shouldCall = true
                        }
                    }
                    if shouldCall {
                        initialCompletion?()
                    }
                }
            }
        }
        group.notify(queue: carouselValidationQueue) {
            var shouldCall = false
            initialSent.changeValue { value in
                if !value {
                    value = true
                    shouldCall = true
                }
            }
            if shouldCall {
                initialCompletion?()
            }
            completion?()
        }
    }

    /// Token-scoped final state write. Only applies the state transition when `validationToken`
    /// is still the active token for `placeholder`. Protects against TOCTOU between a stale
    /// worker's final write and a fresh run's in-flight `.pending`.
    internal func updateImageValidationState(
        messageId: String,
        placeholder: String,
        validationToken: UUID,
        isCorrupted: Bool
    ) {
        let newState: ImageValidationState = isCorrupted ? .corrupted : .valid
        var applied = false
        _imageValidationStates.changeValue { states in
            guard self.carouselValidationTokens[placeholder] == validationToken else { return }
            states[messageId] = newState
            applied = true
        }
        guard applied else { return }
        _inAppContentBlockMessages.changeValue { messages in
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].personalizedMessage?.isCorruptedImage = isCorrupted
            }
        }
    }

    func refreshMessage(message: InAppContentBlockResponse, completion: TypeBlock<InAppContentBlockResponse>?) {
        guard let ids = try? DatabaseManager().currentCustomer.ids else {
            return
        }
        provider.loadPersonalizedInAppContentBlocks(
            data: PersonalizedInAppContentBlockResponseData.self,
            customerIds: ids,
            inAppContentBlocksIds: [message.id]
        ) { [weak self] data in
            guard let self else { return }
            ensureBackground {
                let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data
                    .filter { $0.id == message.id }
                    .compactMap { response in
                        var newInAppContentBlocks = response
                        let normalizeConf = HtmlNormalizerConfig(
                            makeResourcesOffline: true,
                            ensureCloseButton: false
                        )
                        let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                        newInAppContentBlocks.htmlPayload = normalizedPayload
                        let isCorruptedImage = !self.hasHtmlImages(html: response.content?.html ?? "")
                        newInAppContentBlocks.isCorruptedImage = isCorruptedImage
                        return newInAppContentBlocks
                    } ?? []
                if let personal = personalizedWithPayload.first {
                    self._imageValidationStates.changeValue(with: { $0[personal.id] = personal.isCorruptedImage ? .corrupted : .valid })
                }
                var updatedMessage: InAppContentBlockResponse?
                self._inAppContentBlockMessages.changeValue { messages in
                    for (index, inAppContentBlocks) in messages.enumerated() {
                        if let personal = personalizedWithPayload.first, inAppContentBlocks.id == personal.id {
                            var personalized = personal
                            personalized.ttlSeen = Date()
                            if messages[index].personalizedMessage != nil {
                                messages[index].personalizedMessage = personalized
                            }
                            updatedMessage = messages[index]
                        }
                    }
                }
                if let updatedMessage {
                    Exponea.logger.log(.verbose, message: "In-app Content Blocks refreshed personalized: \(updatedMessage.id)")
                    completion?(updatedMessage)
                }
            }
        }
    }

    func refreshCarouselData(placeholder: String, dataCompletion: TypeBlock<[StaticReturnData]>?) {
        Exponea.logger.log(.verbose, message: "In-app Content Blocks refreshStaticViewContent")
        if !isCarouselLoading {
            isCarouselLoading = true
            guard !placeholder.isEmpty, let ids = try? DatabaseManager().currentCustomer.ids else {
                Exponea.logger.log(.verbose, message: "In-app Content Blocks Carousel cant refresh placeholderId: \(placeholder), ids: \(String(describing: try? DatabaseManager().currentCustomer.ids))")
                isCarouselLoading = false
                return
            }
            let idsForDownload = inAppContentBlockMessages.filter { $0.placeholders.contains(placeholder) }.map { $0.id }
            provider.loadPersonalizedInAppContentBlocks(
                data: PersonalizedInAppContentBlockResponseData.self,
                customerIds: ids,
                inAppContentBlocksIds: idsForDownload
            ) { [weak self] data in
                guard let self else { return }
                ensureBackground {
                    let refreshStaticViewContentDescriptions = (data.data?.data ?? []).map { $0.describeDetailed() }
                    Exponea.logger.log(.verbose, message: "In-app Content Blocks refreshStaticViewContent data: \(refreshStaticViewContentDescriptions)")
                    let personalizedWithPayload: [PersonalizedInAppContentBlockResponse] = data.data?.data.compactMap { response in
                        var newInAppContentBlocks = response
                        let normalizeConf = HtmlNormalizerConfig(
                            makeResourcesOffline: true,
                            ensureCloseButton: false
                        )
                        let normalizedPayload = HtmlNormalizer(newInAppContentBlocks.content?.html ?? "").normalize(normalizeConf)
                        newInAppContentBlocks.htmlPayload = normalizedPayload
                        let isCorruptedImage = !self.hasHtmlImages(html: response.content?.html ?? "")
                        newInAppContentBlocks.isCorruptedImage = isCorruptedImage
                        return newInAppContentBlocks
                    } ?? []
                    self._imageValidationStates.changeValue { state in
                        personalizedWithPayload.forEach { personalized in
                            state[personalized.id] = personalized.isCorruptedImage ? .corrupted : .valid
                        }
                    }
                    var updatedContentBlocksForTelemetry: [InAppContentBlockResponse] = []
                    self._inAppContentBlockMessages.changeValue { messages in
                        for (index, inAppContentBlocks) in messages.enumerated() {
                            if var personalized = personalizedWithPayload.first(where: { $0.id == inAppContentBlocks.id }) {
                                personalized.ttlSeen = Date()
                                messages[index].personalizedMessage = personalized
                                updatedContentBlocksForTelemetry.append(messages[index])
                            }
                        }
                    }
                    self.trackTelemetryForFetch(.contentBlockPersonalisedFetch, updatedContentBlocksForTelemetry)
                    let toReturn = self.inAppContentBlockMessages.filter { $0.placeholders.contains(placeholder) }
                        .compactMap { response in
                            self.prepareCarouselStaticData(messages: response)
                        }
                    dataCompletion?(toReturn)
                    self.continueWithCarouselQueue(dataCompletion: dataCompletion)
                }
            }
        } else {
            _carouselQueue.changeValue(with: { $0.append(placeholder) })
        }
    }

    func refreshStaticViewContent(staticQueueData: StaticQueueData) {
        // Public API: host apps may call from any thread. All access to `staticQueue` and
        // `isStaticUpdating` is serialized on the main queue — hop there unconditionally.
        onMain { [weak self] in
            guard let self else { return }
            Exponea.logger.log(.verbose, message: "In-app Content Blocks refreshStaticViewContent")
            self.staticQueue.append(staticQueueData)
            guard !self.isStaticUpdating else { return }
            self.isStaticUpdating = true
            self.scheduleBatchProcessing()
        }
    }

    func prepareCarouselStaticData(
        messages: InAppContentBlockResponse
    ) -> StaticReturnData? {
        // Found message
        guard var message = filterPersonalizedMessages(input: messages.personalizedMessage?.status == .ok ? [messages] : []) else {
            Exponea.logger.log(.verbose, message: "In-app Content Blocks prepareInAppContentBlocksStaticView message not found.")
            return nil
        }
        message.status = getDisplayState(of: message.id)
        Exponea.logger.log(
            .verbose,
            message: "In-app Content Blocks prepareInAppContentBlocksStaticView message \(message.describe())."
        )

        // Add random for 100% unique
        let tag = createUniqueTag(placeholder: message)
        Exponea.logger.log(.verbose, message: "In-app Content Blocks prepareInAppContentBlocksStaticView tag \(tag).")

        message.tags?.insert(tag)

        if let personalized = message.personalizedMessage, let payloadData = personalized.htmlPayload?.html?.data(using: .utf8), !payloadData.isEmpty {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks prepareInAppContentBlocksStaticView personalized \(personalized.describeDetailed())."
            )
            _inAppContentBlockMessages.changeValue { messages in
                guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
                if messages[idx].personalizedMessage?.ttlSeen == nil {
                    messages[idx].personalizedMessage?.ttlSeen = Date()
                }
            }
            if let html = personalized.htmlPayload?.html, !html.isEmpty {
                return .init(html: html, tag: tag, message: message)
            }
        } else {
            Exponea.logger.log(
                .verbose,
                message: "In-app Content Blocks prepareInAppContentBlocksStaticView static \(message.describe())."
            )
            if let html = message.content?.html, !html.isEmpty {
                return .init(html: html, tag: tag, message: message)
            }
        }
        return nil
    }
}

// Synchro
private extension InAppContentBlocksManager {
    func continueWithQueue() {
        isUpdating = false
        if !queue.isEmpty {
            let go = queue.removeFirst()
            Exponea.logger.log(.verbose, message: "In-app Content Blocks continueWithQueue data: \(go.describeDetailed())")
            loadContentForPlacehoder(newValue: go.newValue, message: go.inAppContentBlocks)
        }
    }

    func loadContentForPlacehoder(newValue: UsedInAppContentBlocks, message: InAppContentBlockResponse) {
        if !isUpdating {
            isUpdating = true
            let savedNewValue = newValue
            let savedPlaceholder = message
            loadPersonalizedInAppContentBlocks(for: savedNewValue.messageId, tags: [savedNewValue.tag], skipLoad: true) { [weak self] in
                guard let self else { return }
                self.calculator = .init()
                self.calculator.heightUpdate = { height in
                    let tag = self.createUniqueTag(placeholder: message)
                    Exponea.logger.log(.verbose, message: "In-app Content Blocks loadContentForPlacehoder calculator data \(height)")
                    // Update display status
                    self.updateDisplayedState(for: message.id)
                    self._inAppContentBlockMessages.changeValue { messages in
                        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
                        messages[idx].tags?.insert(tag)
                        messages[idx].indexPath = savedPlaceholder.indexPath
                    }
                    Exponea.logger.log(.verbose, message: "In-app Content Blocks loadContentForPlacehoder count \(self.inAppContentBlockMessages.count)")
                    Exponea.logger.log(.verbose, message: "In-app Content Blocks loadContentForPlacehoder \(self.inAppContentBlockMessages.map { $0.describe() })")
                    Exponea.logger.log(.verbose, message:
                        """
                        In-app Content Blocks loadContentForPlacehoder(newValue: UsedInAppContentBlocks, placeholder: InAppContentBlockResponse)
                        newValue: \(newValue.describeDetailed())
                        placeholder: \(message.describe())
                        """
                    )
                    let placeholderValueFromUsedLine = savedNewValue.placeholder
                    let savedInAppContentBlocksToDeactived = self.usedInAppContentBlocks[placeholderValueFromUsedLine] ?? []
                    if savedInAppContentBlocksToDeactived.isEmpty {
                        self._usedInAppContentBlocks.changeValue { store in
                            let newSavedInAppContentBlocks: UsedInAppContentBlocks = .init(tag: savedNewValue.tag, indexPath: savedNewValue.indexPath, messageId: savedPlaceholder.id, placeholder: savedNewValue.placeholder, height: height.height, placeholderData: savedPlaceholder)
                            if store[placeholderValueFromUsedLine] == nil {
                                store[placeholderValueFromUsedLine] = [newSavedInAppContentBlocks]
                            } else if store[placeholderValueFromUsedLine]?.isEmpty == true {
                                store[placeholderValueFromUsedLine]?.append(newSavedInAppContentBlocks)
                            }
                        }
                        self.continueWithQueue()
                        self.calculator.heightUpdate = nil
                        self.refreshCallback?(savedNewValue.indexPath)
                    } else {
                        if let indexOfSavedInAppContentBlocks: Int = self.usedInAppContentBlocks[placeholderValueFromUsedLine]?.firstIndex(where: { $0.indexPath == savedPlaceholder.indexPath && $0.height == 0 }) {
                            if var savedInAppContentBlocks = self.usedInAppContentBlocks[placeholderValueFromUsedLine]?[indexOfSavedInAppContentBlocks] {
                                if savedInAppContentBlocks.height == 0 {
                                    savedInAppContentBlocks.height = height.height
                                }
                                self._usedInAppContentBlocks.changeValue(with: { $0[placeholderValueFromUsedLine]?.insert(savedInAppContentBlocks, at: indexOfSavedInAppContentBlocks) })
                            }
                        } else {
                            let newSavedInAppContentBlocks: UsedInAppContentBlocks = .init(tag: savedNewValue.tag, indexPath: savedNewValue.indexPath, messageId: savedPlaceholder.id, placeholder: savedNewValue.placeholder, height: height.height, placeholderData: savedPlaceholder)
                            self._usedInAppContentBlocks.changeValue { store in
                                if store[placeholderValueFromUsedLine]?.contains(where: { $0.indexPath == newSavedInAppContentBlocks.indexPath && $0.messageId == newSavedInAppContentBlocks.messageId && $0.height == 0 }) == false {
                                    store[placeholderValueFromUsedLine]?.append(newSavedInAppContentBlocks)
                                }
                            }
                        }
                        self.continueWithQueue()
                        self.calculator.heightUpdate = nil
                        self.refreshCallback?(savedNewValue.indexPath)
                    }
                }
                guard let html = self.inAppContentBlockMessages.first(where: { $0.tags?.contains(newValue.tag) == true })?.personalizedMessage?.htmlPayload?.html, !html.isEmpty else {
                    onMain { self.isUpdating = false }
                    return
                }
                self.calculator.loadHtml(placedholderId: message.id, html: html)
            }
        } else {
            Exponea.logger.log(.verbose, message:
                """
                In-app Content Blocks added to queue
                newValue: \(newValue.describeDetailed())
                placeholder: \(message.describe())
                """
            )
            _queue.changeValue(with: { $0.append(.init(inAppContentBlocks: message, newValue: newValue)) })
        }
    }
}

// Display and Interaction state
extension InAppContentBlocksManager {

    /// Stores timestamp of interaction (click/close) for given In-app content block message ID
    func updateInteractedState(for messageId: String) {
        Exponea.shared.inAppContentBlockStatusStore.didInteract(with: messageId, at: Date())
    }

    /// Stores timestamp of displaying (show) of given In-app content block message ID
    func updateDisplayedState(for messageId: String) {
        Exponea.shared.inAppContentBlockStatusStore.didDisplay(of: messageId, at: Date())
    }

    func getDisplayState(of messageId: String) -> InAppContentBlocksDisplayStatus {
        Exponea.shared.inAppContentBlockStatusStore.status(for: messageId)
    }
}
