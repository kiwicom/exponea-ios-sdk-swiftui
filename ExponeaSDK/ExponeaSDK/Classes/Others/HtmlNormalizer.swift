//
// Created by Adam Mihalik on 23/06/2022.
// Copyright (c) 2022 Exponea. All rights reserved.
//

import Foundation
import SwiftSoup
import WebKit

public class HtmlNormalizer {

    public static let offlineResourceScheme = "exponea-cache"

    private let closeActionCommandUrlPrefix = "https://exponea.com/close_action_"
    private let closeButtonAttrDef = "data-actiontype='close'"
    private let closeButtonSelector = "[data-actiontype='close']"
    private let actionButtonAttr = "data-link"
    private let dataLinkTypeAttr = "data-actiontype"
    private let actionLinkResetClass = "exponea-action-link-reset"
    private let actionLinkResetStyleId = "exponea-action-link-reset-style"

    private let hrefAttr = "href"
    private let anchorTagSelector = "a"

    private let imageMimetype = "image/png"
    private let fontMimetype = "application/font"

    private let cssUrlRegexp = try! NSRegularExpression(
        pattern: "url\\((.+?)\\)",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private let cssImportUrlRegexp = try! NSRegularExpression(
        pattern: "@import[\\s]+url\\(.+?\\)",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let cssKeyFormat = "-?[_a-zA-Z]+[_a-zA-Z0-9-]*"
    private static let cssDelimiterFormat = "[\\s]*:[\\s]*"
    private static let cssValueFormat = "[^;\\n]+"
    private static let keyGroupName = "attrKey"
    private static let valueGroupName = "attrVal"

    /**
     Valid CSS key is defined https://www.w3.org/TR/CSS21/syndata.html#characters
     */
    private let cssAttributeRegexp = try! NSRegularExpression(
        pattern: "(?<\(keyGroupName)>\(cssKeyFormat))\(cssDelimiterFormat)(?<\(valueGroupName)>\(cssValueFormat))",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    /**
     Inline javascript attributes. Listed here https://www.w3schools.com/tags/ref_eventattributes.asp
     */
    private let inlineScriptAttributes: Set<String> = [
        "onafterprint", "onbeforeprint", "onbeforeunload", "onerror", "onhashchange", "onload", "onmessage",
        "onoffline", "ononline", "onpagehide", "onpageshow", "onpopstate", "onresize", "onstorage", "onunload",
        "onblur", "onchange", "oncontextmenu", "onfocus", "oninput", "oninvalid", "onreset", "onsearch",
        "onselect", "onsubmit", "onkeydown", "onkeypress", "onkeyup", "onclick", "ondblclick", "onmousedown",
        "onmousemove", "onmouseout", "onmouseover", "onmouseup", "onmousewheel", "onwheel", "ondrag",
        "ondragend", "ondragenter", "ondragleave", "ondragover", "ondragstart", "ondrop", "onscroll", "oncopy",
        "oncut", "onpaste", "onabort", "oncanplay", "oncanplaythrough", "oncuechange", "ondurationchange",
        "onemptied", "onended", "onerror", "onloadeddata", "onloadedmetadata", "onloadstart", "onpause",
        "onplay", "onplaying", "onprogress", "onratechange", "onseeked", "onseeking", "onstalled", "onsuspend",
        "ontimeupdate", "onvolumechange", "onwaiting", "ontoggle"
    ]

    private let anchorLinkAttributes: Set<String> = [
        "download", "ping", "target"
    ]

    private let supportedCssUrlProperties: Set<String> = [
        "background", "background-image", "border-image", "border-image-source", "content", "cursor", "filter",
        "list-style", "list-style-image", "mask", "mask-image", "offset-path", "src"
    ]

    private var document: Document?
    private var actionAnchorStyleInjected = false

    // MARK: - Test-support accessors

    static func encodeOfflineResourceUrl(sourceUrl: String, type: String) -> String? {
        guard let resourceType = OfflineResourceType(rawValue: type) else { return nil }
        return offlineResourceUrl(sourceUrl: sourceUrl, type: resourceType)
    }

    static func decodeOfflineResourceUrl(_ urlString: String) -> (sourceUrl: String, type: String)? {
        guard let url = URL(string: urlString),
              let result = decodeOfflineResource(url) else { return nil }
        return (result.sourceUrl, result.type.rawValue)
    }

    public static func createWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configureOfflineResources(for: configuration)
        return configuration
    }

    public static func configureOfflineResources(for configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: offlineResourceScheme) == nil {
            configuration.setURLSchemeHandler(OfflineResourceSchemeHandler(), forURLScheme: offlineResourceScheme)
        }
    }

    public init(_ originalHtml: String) {
        do {
            document = try SwiftSoup.parse(originalHtml)
            document?.outputSettings().prettyPrint(pretty: false)
        } catch {
            Exponea.logger.log(
                    .warning,
                    message: "[HTML] Unable to parse original HTML source code \(originalHtml)"
            )
            document = nil
        }
    }

    public func normalize(_ config: HtmlNormalizerConfig? = nil) -> NormalizedResult {
        let parsingConf = config ?? HtmlNormalizerConfig(
            makeResourcesOffline: true, ensureCloseButton: true
        )
        var result = NormalizedResult()
        do {
            let context = try measureStep {
                try prepareNormalizationContext(makeResourcesOffline: parsingConf.makeResourcesOffline)
            }
            var actionAnchors = context.actionAnchorElements
            var closeButtons = context.closeButtonElements
            if parsingConf.makeResourcesOffline {
                try measureStep {
                    try makeResourcesToBeOffline(context)
                }
            }
            try measureStep {
                try normalizeCloseButtons(
                    parsingConf.ensureCloseButton,
                    closeButtons: &closeButtons,
                    actionAnchors: &actionAnchors
                )
            }
            try result.actions = measureStep {
                try normalizeDataLinkButtons(context.dataLinkElements, actionAnchors: &actionAnchors)
                return try collectAnchorLinkButtons(actionAnchors)
            }
            result.html = measureStep {
                exportHtml()
            }
        } catch let error {
            Exponea.logger.log(.error, message: "[HTML] Html has not been processed due to error \(error)")
            result.valid = false
        }
        return result
    }

    private func exportHtml() -> String? {
        guard let document = document else {
            Exponea.logger.log(.warning, message: "[HTML] Document has not been initialized, no HTML to export")
            return nil
        }
        do {
            document.outputSettings().prettyPrint(pretty: false)
            return try document.html()
        } catch let error {
            Exponea.logger.log(.error, message: "[HTML] Output cannot be exported: \(error)")
            return nil
        }
    }

    private func collectAnchorLinkButtons(_ actionButtons: [Element]) throws -> [ActionInfo] {
        var result: [String: ActionInfo] = [:]
        for actionButton in actionButtons {
            let targetAction = try actionButton.attr(hrefAttr)
            if targetAction.isEmpty {
                Exponea.logger.log(.error, message: "[HTML] Action button found but with empty action")
                continue
            }
            let actionType: ActionType
            if let datalinkType = ActionType(rawValue: try actionButton.attr(dataLinkTypeAttr)) {
                actionType = datalinkType
            } else if targetAction.hasPrefix("http://") || targetAction.hasPrefix("https://") {
                actionType = .browser
            } else {
                actionType = .deeplink
            }
            var buttonLabel: String? = try actionButton.text()
            if buttonLabel != nil && buttonLabel!.isEmpty {
                // Close X button produces empty string
                buttonLabel = nil
            }
            if result[targetAction] != nil {
                Exponea.logger.log(.error, message: "[HTML] Action button found but with duplicate action \(targetAction)")
                continue
            }
            result[targetAction] = ActionInfo(
                buttonText: buttonLabel,
                actionUrl: targetAction,
                actionType: actionType
            )
        }
        return Array(result.values)
    }

    private func normalizeDataLinkButtons(
        _ actionButtons: [Element],
        actionAnchors: inout [Element]
    ) throws {
        for actionButton in actionButtons {
            let targetAction = try actionButton.attr(actionButtonAttr)
            if targetAction.isEmpty {
                Exponea.logger.log(.error, message: "[HTML] Action button found but with empty action")
                continue
            }
            let actionType: ActionType
            if let datalinkType = ActionType(rawValue: try actionButton.attr(dataLinkTypeAttr)) {
                actionType = datalinkType
            } else if targetAction.hasPrefix("http://") || targetAction.hasPrefix("https://") {
                actionType = .browser
            } else {
                actionType = .deeplink
            }
            if try actionButton.iS(anchorTagSelector) {
                Exponea.logger.log(.verbose, message: "[HTML] Applying data-link to an a-href link")
                try applyActionInfo(actionButton, url: targetAction, actionType: actionType)
                appendUniqueElement(actionButton, to: &actionAnchors)
            } else if let parent = actionButton.parent(), try parent.iS(anchorTagSelector) {
                Exponea.logger.log(.verbose, message: "[HTML] Applying data-link to a parent as an a-href link")
                try applyActionInfo(actionButton, url: targetAction, actionType: actionType)
                try applyActionInfo(parent, url: targetAction, actionType: actionType)
                appendUniqueElement(parent, to: &actionAnchors)
            } else {
                Exponea.logger.log(.verbose, message: "[HTML] Wrapping data-link with an a-href")
                try applyActionInfo(actionButton, url: targetAction, actionType: actionType)
                if let wrapper = try wrapWithAnchorLink(actionButton, href: targetAction, actionType: actionType) {
                    appendUniqueElement(wrapper, to: &actionAnchors)
                }
            }
        }
    }

    private func normalizeCloseButtons(
        _ ensureCloseButton: Bool,
        closeButtons: inout [Element],
        actionAnchors: inout [Element]
    ) throws {
        guard let document = document,
              let htmlBody = document.body(),
              let htmlHead = document.head() else {
            // defined or default has to exist
            throw ExponeaError.unknownError("Action close cannot be ensured")
        }
        if closeButtons.isEmpty && ensureCloseButton {
            Exponea.logger.log(
                    .verbose,
                    message: "[HTML] Adding default close-button"
            )
            // randomize class name => prevents from CSS styles overriding in HTML
            let closeButtonClass = "close-button-\(UUID().uuidString)"
            let buttonSize = "max(min(5vw, 5vh), 16px)"
            try htmlBody.append("<div \(closeButtonAttrDef) class='\(closeButtonClass)'><div>")
            try htmlHead.append("""
                        <style>
                            .\(closeButtonClass) {
                              display: inline-block;
                              position: absolute;
                              width: \(buttonSize);
                              height: \(buttonSize);
                              top: 10px;
                              right: 10px;
                              cursor: pointer;
                              border-radius: 50%;
                              background-color: rgba(250, 250, 250, 0.6);
                             }
                            .\(closeButtonClass):before {
                              content: '×';
                              position: absolute;
                              display: flex;
                              justify-content: center;
                              width: \(buttonSize);
                              height: \(buttonSize);
                              color: rgb(0, 0, 0);
                              font-size: \(buttonSize);
                              line-height: \(buttonSize);
                            }
                        </style>
                        """)
            closeButtons += try document.select(closeButtonSelector).array()
        }
        for closeButton in closeButtons {
            let closeButtonId = UUID().uuidString
            let closeButtonUrl = closeActionCommandUrlPrefix + "_" + closeButtonId
            if try closeButton.iS(anchorTagSelector) {
                Exponea.logger.log(
                        .verbose,
                        message: "[HTML] Fixing close button as a-href link to close action"
                )
                try applyActionInfo(closeButton, url: closeButtonUrl, actionType: .close)
                appendUniqueElement(closeButton, to: &actionAnchors)
            } else if let closeButtonParent = closeButton.parent(), try closeButtonParent.iS(anchorTagSelector) {
                Exponea.logger.log(
                        .verbose,
                        message: "[HTML] Fixing parent a-href link to close action"
                )
                try applyActionInfo(closeButton, url: closeButtonUrl, actionType: .close)
                try applyActionInfo(closeButtonParent, url: closeButtonUrl, actionType: .close)
                appendUniqueElement(closeButtonParent, to: &actionAnchors)
            } else {
                Exponea.logger.log(.verbose, message: "[HTML] Wrapping Close button with a-href")
                try applyActionInfo(closeButton, url: closeButtonUrl, actionType: .close)
                if let wrapper = try wrapWithAnchorLink(closeButton, href: closeButtonUrl, actionType: .close) {
                    appendUniqueElement(wrapper, to: &actionAnchors)
                }
            }
        }
        if ensureCloseButton && closeButtons.isEmpty {
            // defined or default has to exist
            throw ExponeaError.unknownError("Action close cannot be ensured")
        }
    }

    private func makeResourcesToBeOffline(_ context: NormalizationContext) throws {
        try measureStep {
            try makeImageTagsToBeOffline(context.imageElements)
        }
        try measureStep {
            try makeStylesheetsToBeOffline(context.styleTagStatements)
        }
        try measureStep {
            try makeStyleAttributesToBeOffline(context.styleAttributeStatements)
        }
    }

    private func makeImageTagsToBeOffline(_ imageElements: [Element]) throws {
        for imageEl in imageElements {
            do {
                let source = try imageEl.attr("src")
                guard shouldRewriteToOfflineResource(source) else {
                    continue
                }
                try imageEl.attr("src", makeOfflineResourceUrl(source, mimeType: imageMimetype))
            } catch let error {
                let elSelector = try? imageEl.cssSelector()
                Exponea.logger.log(
                    .error,
                    message: "[HTML] Image \(elSelector ?? "<unknown>") cannot be processed: \(error.localizedDescription)"
                )
                throw error
            }
        }
    }

    private func makeStyleAttributesToBeOffline(_ styledElements: [(element: Element, statements: [CssOnlineUrl])]) throws {
        for styledElement in styledElements {
            let styledEl = styledElement.element
            let styleAttrSource = try styledEl.attr("style")
            do {
                try styledEl.attr("style", downloadOnlineResources(styleAttrSource, styledElement.statements))
            } catch let error {
                let elSelector = try? styledEl.cssSelector()
                Exponea.logger.log(
                    .error,
                    message: "[HTML] Element \(elSelector ?? "<unknown>") not updated: \(error.localizedDescription)"
                )
                throw error
            }
        }
    }

    private func downloadOnlineResources(_ styleSource: String, _ onlineStatements: [CssOnlineUrl]? = nil) -> String {
        let statements = onlineStatements ?? collectUrlStatements(styleSource)
        var styleTarget = styleSource
        for statement in statements {
            let rewrittenUrl: String
            switch statement.mimeType {
            case fontMimetype:
                rewrittenUrl = makeOfflineResourceUrl(statement.url, mimeType: fontMimetype)
            case imageMimetype:
                rewrittenUrl = makeOfflineResourceUrl(statement.url, mimeType: imageMimetype)
            default:
                Exponea.logger.log(.error, message: "Unsupported mime type \(statement.mimeType)")
                continue
            }
            guard shouldRewriteToOfflineResource(statement.url) else {
                continue
            }
            styleTarget = styleTarget.replacingOccurrences(
                of: statement.url,
                with: rewrittenUrl
            )
        }
        return styleTarget
    }

    private func makeStylesheetsToBeOffline(_ styleTags: [(element: Element, statements: [CssOnlineUrl])]) throws {
        for styledElement in styleTags {
            let styleSource = styledElement.element.data()
            do {
                try styledElement.element.text(downloadOnlineResources(styleSource, styledElement.statements))
            } catch let error {
                Exponea.logger.log(.error, message: "[HTML] Element <style> not updated: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func collectUrlStatements(_ cssStyle: String) -> [CssOnlineUrl] {
        guard cssStyle.range(of: "url(", options: .caseInsensitive) != nil else {
            return []
        }
        var result: [CssOnlineUrl] = []
        // CSS @import search
        let cssImportMatches = cssImportUrlRegexp.matchesAsStrings(in: cssStyle)
        for importRule in cssImportMatches {
            let importUrlMatches = cssUrlRegexp.groupsAsStrings(in: importRule)
            for importUrl in importUrlMatches {
                result.append(CssOnlineUrl(
                    mimeType: fontMimetype,
                    url: importUrl.trimmingCharacters(in: CharacterSet(["'", "\""]))
                ))
            }
        }
        // CSS definitions search
        let cssDefinitionMatches = cssAttributeRegexp.matches(in: cssStyle)
        for cssDefinitionMatch in cssDefinitionMatches {
            guard let cssKey = cssDefinitionMatch.rangeAsString(
                withName: HtmlNormalizer.keyGroupName,
                from: cssStyle
            )?.lowercased() else {
                continue
            }
            if !supportedCssUrlProperties.contains(cssKey) {
                // skip
                continue
            }
            let cssValue = cssDefinitionMatch.rangeAsString(
                withName: HtmlNormalizer.valueGroupName,
                from: cssStyle
            )
            guard let cssValue = cssValue else {
                continue
            }
            let urlValueMatches = cssUrlRegexp.groupsAsStrings(in: cssValue)
            for urlValue in urlValueMatches {
                result.append(CssOnlineUrl(
                    mimeType: cssKey == "src" ? fontMimetype : imageMimetype,
                    url: urlValue.trimmingCharacters(in: CharacterSet(["'", "\""]))
                ))
            }
        }
        return result
    }

    public func collectImages() -> [String] {
        guard let document = document else {
            Exponea.logger.log(.warning, message: "[HTML] Document has not been initialized, no Image to process")
            return []
        }
        var onlineUrls: [String] = []
        // images
        do {
            for imageEl in try document.select("img").array() {
                guard let imgSrc = try? imageEl.attr("src"),
                      !imgSrc.isEmpty,
                      !isBase64Uri(imgSrc) else {
                    continue    // empty or offline src
                }
                onlineUrls.append(imgSrc)
            }
        } catch let error {
            Exponea.logger.log(.warning, message: "[HTML] Failure while reading image source: \(error)")
        }
        // style tags
        do {
            for styleTag in try document.select("style").array() {
                let styleSource = styleTag.data()
                let onlineSources = collectUrlStatements(styleSource)
                let imageOnlineSources = onlineSources.filter { $0.mimeType == imageMimetype }
                onlineUrls.append(contentsOf: imageOnlineSources.map { $0.url })
            }
        } catch let error {
            Exponea.logger.log(.warning, message: "[HTML] Failure while reading style tag source: \(error)")
        }
        // style attributes
        do {
            for styledEl in try document.select("[style]").array() {
                guard let styleAttrSource = try? styledEl.attr("style") else {
                    continue
                }
                let onlineSources = collectUrlStatements(styleAttrSource)
                let imageOnlineSources = onlineSources.filter { $0.mimeType == imageMimetype }
                onlineUrls.append(contentsOf: imageOnlineSources.map { $0.url })
            }
        } catch let error {
            Exponea.logger.log(.warning, message: "[HTML] Failure while reading style attribute source: \(error)")
        }
        // end
        return onlineUrls
    }

    public func collectFonts() -> [String] {
        guard let document = document else {
            Exponea.logger.log(.warning, message: "[HTML] Document has not been initialized, no Font to process")
            return []
        }
        var onlineUrls: [String] = []
        do {
            for styleTag in try document.select("style").array() {
                let styleSource = styleTag.data()
                let onlineSources = collectUrlStatements(styleSource)
                let fontOnlineSources = onlineSources.filter { $0.mimeType == fontMimetype }
                onlineUrls.append(contentsOf: fontOnlineSources.map { $0.url })
            }
        } catch let error {
            Exponea.logger.log(.warning, message: "[HTML] Failure while reading style tag font source: \(error)")
        }
        do {
            for styledEl in try document.select("[style]").array() {
                guard let styleAttrSource = try? styledEl.attr("style") else {
                    continue
                }
                let onlineSources = collectUrlStatements(styleAttrSource)
                let fontOnlineSources = onlineSources.filter { $0.mimeType == fontMimetype }
                onlineUrls.append(contentsOf: fontOnlineSources.map { $0.url })
            }
        } catch let error {
            Exponea.logger.log(.warning, message: "[HTML] Failure while reading style attribute font source: \(error)")
        }
        return onlineUrls
    }

    public func collectRenderResources() -> RenderResources {
        RenderResources(
            imageUrls: Set(collectImages().filter { shouldRewriteToOfflineResource($0) }),
            fontUrls: Set(collectFonts().filter { shouldRewriteToOfflineResource($0) })
        )
    }

    /**
     According to https://en.wikipedia.org/wiki/Data_URI_scheme#Syntax
     data:[<media type>][;charset=<character set>][;base64],<data>
     */
    private func isBase64Uri(_ uri: String?) -> Bool {
        guard let uri = uri else {
            return false
        }
        return uri.starts(with: "data:") && uri.contains("base64,")
    }

    private func shouldRewriteToOfflineResource(_ resourceUrl: String?) -> Bool {
        guard let resourceUrl = resourceUrl,
              !resourceUrl.isEmpty,
              !isBase64Uri(resourceUrl),
              !resourceUrl.lowercased().hasPrefix("\(HtmlNormalizer.offlineResourceScheme):"),
              let scheme = URL(safeString: resourceUrl)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func makeOfflineResourceUrl(_ resourceUrl: String, mimeType: String) -> String {
        let resourceType: OfflineResourceType = mimeType == fontMimetype ? .font : .image
        return HtmlNormalizer.offlineResourceUrl(sourceUrl: resourceUrl, type: resourceType) ?? resourceUrl
    }

    private func prepareNormalizationContext(makeResourcesOffline: Bool) throws -> NormalizationContext {
        guard let document = document else {
            Exponea.logger.log(.warning, message: "[HTML] Document has not been initialized, no HTML to normalize")
            return NormalizationContext()
        }
        var context = NormalizationContext()
        var removedElements: [Element] = []
        for element in try document.getAllElements().array() {
            let tagName = element.tagNameNormal()
            if tagName == "script"
                || tagName == "title"
                || tagName == "iframe"
                || tagName == "link" {
                removedElements.append(element)
                continue
            }
            if tagName == "meta", try element.attr("name").lowercased() != "viewport" {
                removedElements.append(element)
                continue
            }
            if tagName != anchorTagSelector {
                try element.removeAttr(hrefAttr)
            }
            try cleanElementAttributes(element)
            if tagName == anchorTagSelector && element.hasAttr(hrefAttr) {
                appendUniqueElement(element, to: &context.actionAnchorElements)
            }
            let actionTypeAttr = try element.attr(dataLinkTypeAttr)
            if actionTypeAttr.lowercased() == ActionType.close.rawValue {
                context.closeButtonElements.append(element)
            } else if element.hasAttr(actionButtonAttr) {
                context.dataLinkElements.append(element)
            }
            if makeResourcesOffline {
                if tagName == "img" {
                    context.imageElements.append(element)
                }
                if tagName == "style" {
                    context.styleTagStatements.append(
                        (element: element, statements: collectUrlStatements(element.data()))
                    )
                }
                if element.hasAttr("style") {
                    context.styleAttributeStatements.append(
                        (element: element, statements: collectUrlStatements(try element.attr("style")))
                    )
                }
            }
        }
        for element in removedElements {
            try element.remove()
        }
        return context
    }

    private func cleanElementAttributes(_ element: Element) throws {
        guard let attributes = element.getAttributes()?.asList() else {
            return
        }
        for attribute in attributes {
            let attributeKey = attribute.getKey()
            let normalizedAttributeKey = attributeKey.lowercased()
            if anchorLinkAttributes.contains(normalizedAttributeKey)
                || inlineScriptAttributes.contains(normalizedAttributeKey) {
                try element.removeAttr(attributeKey)
            }
        }
    }

    private func applyActionInfo(_ target: Element, url: String, actionType: ActionType) throws {
        if try target.iS(anchorTagSelector) {
            try target.attr(hrefAttr, url)
        }
        try target.attr(actionButtonAttr, url)
        try target.attr(dataLinkTypeAttr, actionType.rawValue)
    }

    private func wrapWithAnchorLink(_ child: Element, href: String, actionType: ActionType) throws -> Element? {
        try ensureActionAnchorStyle()
        let anchor = Element(try Tag.valueOf("a"), "")
        try anchor.attr(hrefAttr, href)
        try anchor.addClass(actionLinkResetClass)
        try anchor.attr(actionButtonAttr, href)
        try anchor.attr(dataLinkTypeAttr, actionType.rawValue)
        try child.before(anchor)
        try anchor.appendChild(child)
        return anchor
    }

    private func ensureActionAnchorStyle() throws {
        if actionAnchorStyleInjected {
            return
        }
        guard let document = document,
              let htmlHead = document.head() else {
            return
        }
        if try htmlHead.select("#\(actionLinkResetStyleId)").isEmpty() {
            try htmlHead.append("""
                <style id='\(actionLinkResetStyleId)'>
                .\(actionLinkResetClass) {
                    text-decoration: none;
                }
                </style>
                """)
        }
        actionAnchorStyleInjected = true
    }

    private func appendUniqueElement(_ element: Element, to elements: inout [Element]) {
        if elements.contains(where: { $0 === element }) {
            return
        }
        elements.append(element)
    }

    fileprivate enum OfflineResourceType: String {
        case image
        case font
    }

    fileprivate static func offlineResourceUrl(sourceUrl: String, type: OfflineResourceType) -> String? {
        guard let token = encodeOfflineResourceToken(sourceUrl) else {
            return nil
        }
        return "\(offlineResourceScheme)://\(type.rawValue)/\(token)"
    }

    fileprivate static func decodeOfflineResource(_ url: URL) -> (sourceUrl: String, type: OfflineResourceType)? {
        guard url.scheme?.lowercased() == offlineResourceScheme,
              let host = url.host,
              let type = OfflineResourceType(rawValue: host) else {
            return nil
        }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !token.isEmpty,
              let sourceUrl = decodeOfflineResourceToken(token) else {
            return nil
        }
        return (sourceUrl, type)
    }

    fileprivate static func encodeOfflineResourceToken(_ sourceUrl: String) -> String? {
        guard let sourceData = sourceUrl.data(using: .utf8) else {
            return nil
        }
        return sourceData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func decodeOfflineResourceToken(_ token: String) -> String? {
        var base64Token = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64Token.count % 4
        if remainder > 0 {
            base64Token += String(repeating: "=", count: 4 - remainder)
        }
        guard let sourceData = Data(base64Encoded: base64Token) else {
            return nil
        }
        return String(data: sourceData, encoding: .utf8)
    }

    private struct NormalizationContext {
        var closeButtonElements: [Element] = []
        var dataLinkElements: [Element] = []
        var imageElements: [Element] = []
        var styleTagStatements: [(element: Element, statements: [CssOnlineUrl])] = []
        var styleAttributeStatements: [(element: Element, statements: [CssOnlineUrl])] = []
        var actionAnchorElements: [Element] = []
    }

    @discardableResult
    private func measureStep<T>(_ operation: () throws -> T) rethrows -> T {
        return try operation()
    }

}

private final class OfflineResourceSchemeHandler: NSObject, WKURLSchemeHandler {

    private let imageCache: InAppMessagesCacheType = InAppMessagesCache()
    private let fontCache: FileCacheType = FileCache()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestUrl = urlSchemeTask.request.url,
              let resource = HtmlNormalizer.decodeOfflineResource(requestUrl) else {
            fail(urlSchemeTask, message: "Cannot decode offline resource URL")
            return
        }
        let resourceData: Data?
        switch resource.type {
        case .image:
            resourceData = getImageData(resource.sourceUrl)
        case .font:
            resourceData = getFontData(resource.sourceUrl)
        }
        guard let resourceData = resourceData else {
            fail(urlSchemeTask, message: "Cannot load offline resource \(resource.sourceUrl)")
            return
        }
        let response = URLResponse(
            url: requestUrl,
            mimeType: detectMimeType(resource.type, sourceUrl: resource.sourceUrl),
            expectedContentLength: resourceData.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resourceData)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op. The scheme handler serves cache-only resources and does not own async work.
    }

    private func getImageData(_ sourceUrl: String) -> Data? {
        imageCache.getImageData(at: sourceUrl)
    }

    private func getFontData(_ sourceUrl: String) -> Data? {
        fontCache.getFileData(at: sourceUrl)
    }

    private func detectMimeType(_ resourceType: HtmlNormalizer.OfflineResourceType, sourceUrl: String) -> String {
        let fileExtension = URL(safeString: sourceUrl)?.pathExtension.lowercased() ?? ""
        switch resourceType {
        case .image:
            switch fileExtension {
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "svg":
                return "image/svg+xml"
            case "bmp":
                return "image/bmp"
            case "heic":
                return "image/heic"
            case "heif":
                return "image/heif"
            case "ico":
                return "image/x-icon"
            case "avif":
                return "image/avif"
            default:
                return "image/png"
            }
        case .font:
            switch fileExtension {
            case "woff":
                return "font/woff"
            case "woff2":
                return "font/woff2"
            case "ttf":
                return "font/ttf"
            case "otf":
                return "font/otf"
            case "eot":
                return "application/vnd.ms-fontobject"
            case "svg":
                return "image/svg+xml"
            default:
                return "application/font"
            }
        }
    }

    private func fail(_ task: WKURLSchemeTask, message: String) {
        Exponea.logger.log(.warning, message: "[HTML] \(message)")
        task.didFailWithError(
            NSError(
                domain: "com.exponea.HtmlNormalizer.offlineResource",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}

public enum ParsingError: Error {
    case imageError
}

public struct NormalizedResult {
    public var valid = true
    public var actions: [ActionInfo] = []
    public var html: String?
    public func findActionByUrl(_ url: URL?) -> ActionInfo? {
        guard let url = url else {
            return nil
        }
        return actions.first(where: { action in
            areEqualAsURLs(action.actionUrl, url.absoluteString)
        })
    }
    func isActionUrl(_ url: URL?) -> Bool {
        guard let url = url,
              let action = findActionByUrl(url) else {
            return false
        }
        return action.actionType == .browser || action.actionType == .deeplink
    }
    func isCloseAction(_ url: URL?) -> Bool {
        guard let url = url,
              let action = findActionByUrl(url) else {
            return false
        }
        return action.actionType == .close
    }
    func areEqualAsURLs(_ urlPath1: String?, _ urlPath2: String?) -> Bool {
        guard let urlPath1, let urlPath2 else {
            return false
        }
        let url1 = urlPath1.cleanedURL()
        let scheme1 = url1?.scheme
        let host1 = url1?.host
        let path1 = url1?.path == "/" ? "" : url1?.path
        let query1 = url1?.query
        let url2 = urlPath2.cleanedURL()
        let scheme2 = url2?.scheme
        let host2 = url2?.host
        let path2 = url2?.path == "/" ? "" : url2?.path
        let query2 = url2?.query
        return (
            scheme1 == scheme2
            && host1 == host2
            && path1 == path2
            && query1 == query2
        )
    }
}

public struct RenderResources {
    public let imageUrls: Set<String>
    public let fontUrls: Set<String>

    public var isEmpty: Bool {
        imageUrls.isEmpty && fontUrls.isEmpty
    }
}

internal final class HtmlRenderResourcePreloader {

    private let imageCache: InAppMessagesCacheType
    private let fontCache: FileCacheType
    private let timeout: TimeInterval

    private final class PreloadStats {
        private let lock = NSLock()
        private(set) var allResourcesLoaded = true

        func markFailed() {
            lock.lock()
            allResourcesLoaded = false
            lock.unlock()
        }
    }

    init(
        imageCache: InAppMessagesCacheType = InAppMessagesCache(),
        fontCache: FileCacheType = FileCache(),
        timeout: TimeInterval = 10
    ) {
        self.imageCache = imageCache
        self.fontCache = fontCache
        self.timeout = timeout
    }

    func uncachedResources(from resources: RenderResources) -> RenderResources {
        RenderResources(
            imageUrls: Set(resources.imageUrls.filter { !imageCache.hasImageData(at: $0) }),
            fontUrls: Set(resources.fontUrls.filter { !fontCache.hasFileData(at: $0) })
        )
    }

    func preload(resources: RenderResources) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !resources.isEmpty else {
            return true
        }
        let uncached = uncachedResources(from: resources)
        guard !uncached.isEmpty else {
            return true
        }
        let uncachedImages = Array(uncached.imageUrls)
        let uncachedFonts = Array(uncached.fontUrls)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: sessionConfig)
        let group = DispatchGroup()
        let stats = PreloadStats()

        func markFailed(_ message: String) {
            Exponea.logger.log(.warning, message: "[HTML] \(message)")
            stats.markFailed()
        }

        for imageUrl in uncachedImages {
            guard let url = URL(safeString: imageUrl) else {
                markFailed("Invalid image URL \(imageUrl)")
                continue
            }
            group.enter()
            session.dataTask(with: url) { [imageCache] data, response, error in
                defer { group.leave() }
                guard error == nil else {
                    markFailed("Image preload failed for \(imageUrl): \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard Self.isSuccessful(response), let data, !data.isEmpty else {
                    markFailed("Image preload returned empty or unsuccessful response for \(imageUrl)")
                    return
                }
                imageCache.saveImageData(at: imageUrl, data: data)
            }.resume()
        }

        for fontUrl in uncachedFonts {
            guard let url = URL(safeString: fontUrl) else {
                markFailed("Invalid font URL \(fontUrl)")
                continue
            }
            group.enter()
            session.dataTask(with: url) { [fontCache] data, response, error in
                defer { group.leave() }
                guard error == nil else {
                    markFailed("Font preload failed for \(fontUrl): \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard Self.isSuccessful(response), let data, !data.isEmpty else {
                    markFailed("Font preload returned empty or unsuccessful response for \(fontUrl)")
                    return
                }
                fontCache.saveFileData(at: fontUrl, data: data)
            }.resume()
        }

        let waitResult = group.wait(timeout: .now() + timeout + 1)
        session.invalidateAndCancel()
        if waitResult == .timedOut {
            Exponea.logger.log(.warning, message: "[HTML] Render resource preload timed out")
            return false
        }
        return stats.allResourcesLoaded && validate(resources: resources)
    }

    func prepareNormalizedHtml(
        html: String,
        config: HtmlNormalizerConfig
    ) -> NormalizedResult? {
        let normalizer = HtmlNormalizer(html)
        let resources = config.makeResourcesOffline ? normalizer.collectRenderResources() : RenderResources(
            imageUrls: [],
            fontUrls: []
        )
        if config.makeResourcesOffline && !resources.isEmpty {
            let uncached = uncachedResources(from: resources)
            if !uncached.isEmpty {
                if Thread.isMainThread {
                    Exponea.logger.log(.warning, message: "[HTML] Render resources cannot be preloaded on main thread")
                    return nil
                }
                guard preload(resources: resources) else {
                    return nil
                }
            }
        }
        let normalizedPayload = normalizer.normalize(config)
        guard normalizedPayload.valid,
              let normalizedHtml = normalizedPayload.html,
              !normalizedHtml.isEmpty else {
            return nil
        }
        if config.makeResourcesOffline && !validate(resources: resources) {
            return nil
        }
        return normalizedPayload
    }

    func validate(resources: RenderResources) -> Bool {
        let missingImages = resources.imageUrls.filter { imageCache.hasImageData(at: $0) == false }
        let missingFonts = resources.fontUrls.filter { fontCache.hasFileData(at: $0) == false }
        if !missingImages.isEmpty {
            Exponea.logger.log(.warning, message: "[HTML] Missing offline images: \(missingImages.joined(separator: ","))")
        }
        if !missingFonts.isEmpty {
            Exponea.logger.log(.warning, message: "[HTML] Missing offline fonts: \(missingFonts.joined(separator: ","))")
        }
        return missingImages.isEmpty && missingFonts.isEmpty
    }

    private static func isSuccessful(_ response: URLResponse?) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else {
            return response != nil
        }
        return (200...299).contains(httpResponse.statusCode)
    }

}

public struct ActionInfo {
    public var buttonText: String?
    public var actionUrl: String
    public var actionType: ActionType

    public init(buttonText: String?, actionUrl: String, actionType: ActionType) {
        self.buttonText = buttonText
        self.actionUrl = actionUrl
        self.actionType = actionType
    }
}

public enum ActionType: String {
    case deeplink = "deep-link"
    case browser
    case close
}

public struct HtmlNormalizerConfig {
    public let makeResourcesOffline: Bool
    public let ensureCloseButton: Bool
    public init(makeResourcesOffline: Bool, ensureCloseButton: Bool) {
        self.makeResourcesOffline = makeResourcesOffline
        self.ensureCloseButton = ensureCloseButton
    }
}

private struct CssOnlineUrl {
    public let mimeType: String
    public let url: String
}
