//
//  AsyncImage.swift
//  ExponeaSDK
//
//  Created by Ankmara on 21.11.2024.
//  Copyright © 2024 Exponea. All rights reserved.
//

import Combine
import SwiftUI

/// A view that asynchronously loads and displays an image.
///
/// Loading an image from a URL uses the shared URLSession.
struct ExponeaAsyncImage<Content>: View where Content: View {

    final class Loader: ObservableObject {
        @Published var uiImage: UIImage?
        var imageSize: CGSize { uiImage?.size ?? .zero }
        private var cancellables = Set<AnyCancellable>()
        init(_ url: URL?, scale: CGFloat = 1) {
            guard let url = url else { return }
            URLSession.shared.dataTaskPublisher(for: url)
                .map(\.data)
                .catch { _ in Empty<Data, Never>() }
                .compactMap { data -> UIImage? in
                    UIImage(data: data, scale: scale)
                }
                .receive(on: RunLoop.main)
                .sink { [weak self] image in
                    self?.uiImage = image
                }
                .store(in: &cancellables)
        }
    }

    @ObservedObject private var imageLoader: Loader
    private let conditionalContent: ((SwiftUI.Image?, CGSize) -> Content)?

    /// Loads and displays an image from the given URL.
    ///
    /// When no image is available, standard placeholder content is shown.
    ///
    /// In the example below, the image from the specified URL is loaded and shown.
    ///
    ///     AsyncImage(url: URL(string: "https://example.com/screenshot.png"))
    ///
    /// - Parameters:
    ///   - url: The URL for the image to be shown.
    ///   - scale: The scale to use for the image.
    init(url: URL?, scale: CGFloat = 1) where Content == SwiftUI.Image {
        self.imageLoader = Loader(url, scale: scale)
        self.conditionalContent = nil
    }

    /// Loads and displays an image from the given URL.
    ///
    /// When an image is loaded, the `image` content is shown; when no image is
    /// available, the `placeholder` is shown.
    ///
    /// In the example below, the image from the specified URL is loaded and
    /// shown as a tiled resizable image. While it is loading, a green
    /// placeholder is shown.
    ///
    ///     AsyncImage(url: URL(string: "https://example.com/tile.png")) { image in
    ///         image.resizable(resizingMode: .tile)
    ///     } placeholder: {
    ///         Color.green
    ///     }
    ///
    /// - Parameters:
    ///   - url: The URL for the image to be shown.
    ///   - scale: The scale to use for the image.
    ///   - content: The view to show when the image is loaded.
    ///   - placeholder: The view to show while the image is still loading.
    init<I, P>(url: URL?, scale: CGFloat = 1, @ViewBuilder content: @escaping (SwiftUI.Image, CGSize) -> I, @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P>, I : View, P : View {
        self.imageLoader = Loader(url, scale: scale)
        self.conditionalContent = { image, imageSize in
            if let image = image {
                return ViewBuilder.buildEither(first: content(image, imageSize))
            } else {
                return ViewBuilder.buildEither(second: placeholder())
            }
        }
    }

    private var image: SwiftUI.Image? {
        imageLoader.uiImage.map(SwiftUI.Image.init)
    }

    var body: some View {
        if let conditionalContent = conditionalContent {
            conditionalContent(image, imageLoader.imageSize)
        } else if let image = image {
            image
        }
    }

}
