//
//  InAppCloseButtonComponent.swift
//  ExponeaSDK
//
//  Created by Ankmara on 05.11.2024.
//  Copyright © 2024 Exponea. All rights reserved.
//

import SwiftUI
import UIKit

public struct InAppCloseButton: View {

    public let config: InAppCloseButtonConfig
    private let defaultBackgroundPadding = 8.0

    public init(config: InAppCloseButtonConfig) {
        self.config = config
    }

    public var body: some View {
        Button(action: {
            config.dismissCallback?()
        }) {
            iconView
                .frame(
                    width: config.sizeWithPadding.width,
                    height: config.sizeWithPadding.height
                )
                .background(SwiftUI.Color(InAppCloseButtonOverlay.resolvedBackgroundColor(from: config)))
                .clipShape(RoundedRectangle(cornerRadius: config.size.width / 2 + defaultBackgroundPadding))
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)
        if let imageURL = config.imageURL, let url = URL(string: imageURL) {
            let image = ExponeaAsyncImage(url: url) { image, _ in
                image
                    .resizable()
                    .renderingMode(tint != nil ? .template : .original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: config.size.width, height: config.size.height)
                    .padding(defaultBackgroundPadding)
            } placeholder: {
                fallbackSystemCloseIcon(tint: tint ?? .white)
            }
            if let tint {
                image.foregroundColor(Color(tint))
            } else {
                image
            }
        } else {
            fallbackSystemCloseIcon(tint: tint ?? .white)
        }
    }

    private func fallbackSystemCloseIcon(tint: UIColor) -> some View {
        Image(systemName: "xmark")
            .font(.body.weight(.semibold))
            .foregroundColor(Color(tint))
            .frame(width: config.size.width, height: config.size.height)
            .padding(defaultBackgroundPadding)
    }
}

/// Resolves rich in-app close-button placement and styling from the message payload.
enum InAppCloseButtonOverlay {
    static let defaultBackgroundColor = UIColor.white.withAlphaComponent(0.6)
    static let defaultIconTint = UIColor.black

    static func topPadding(from config: InAppCloseButtonConfig) -> CGFloat {
        config.margin.first(where: { $0.edge == .top })?.value ?? 0
    }

    static func trailingPadding(from config: InAppCloseButtonConfig) -> CGFloat {
        config.margin.first(where: { $0.edge == .trailing })?.value ?? 0
    }

    /// Parsed tint when alpha > 0; `nil` when alpha is 0 (render asset untinted); black when absent/unparseable.
    static func resolvedIconTint(from config: InAppCloseButtonConfig) -> UIColor? {
        guard let iconColor = config.iconColor else {
            return defaultIconTint
        }
        guard let color = UIColor.parse(iconColor) else {
            return defaultIconTint
        }
        if CIColor(color: color).alpha > 0 {
            return color
        }
        return nil
    }

    static func resolvedBackgroundColor(from config: InAppCloseButtonConfig) -> UIColor {
        UIColor.parse(config.backgroundColor) ?? defaultBackgroundColor
    }
}

extension View {
    /// Places the close button above all content at the message container's top-trailing corner.
    func inAppCloseButtonOverlay(config: InAppCloseButtonConfig) -> some View {
        overlay(
            Group {
                if config.visibility {
                    InAppCloseButton(config: config)
                        .padding(.top, InAppCloseButtonOverlay.topPadding(from: config))
                        .padding(.trailing, InAppCloseButtonOverlay.trailingPadding(from: config))
                }
            },
            alignment: .topTrailing
        )
    }
}
