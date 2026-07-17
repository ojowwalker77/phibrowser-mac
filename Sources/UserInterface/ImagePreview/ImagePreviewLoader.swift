// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ImagePreviewLoader: ImagePreviewLoading {
    private final class CacheEntry {
        let asset: ImagePreviewAsset

        init(asset: ImagePreviewAsset) {
            self.asset = asset
        }
    }

    private let urlSession: URLSession
    private let cache = NSCache<NSString, CacheEntry>()
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    private var memoryPressureObserver: NSObjectProtocol?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        cache.countLimit = 3
        cache.totalCostLimit = 128 * 1024 * 1024
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .phiMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit {
        if let memoryPressureObserver {
            NotificationCenter.default.removeObserver(memoryPressureObserver)
        }
    }

    func load(_ item: ImagePreviewItem) async throws -> ImagePreviewAsset {
        if let cached = cache.object(forKey: item.source.cacheKey as NSString)?.asset {
            PerformanceSignposts.event(
                "imagePreview.decode",
                metadata: "source=cache result=hit"
            )
            return cached
        }

        let interval = PerformanceSignposts.begin(
            "imagePreview.decode",
            metadata: "source=\(sourceKind(item.source))"
        )

        let asset: ImagePreviewAsset
        switch item.source {
        case .localFile(let url):
            do {
                asset = try await performUtilityWork {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw ImagePreviewError.fileNotFound
                    }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    return try Self.decode(data: data, sourceURL: url, mimeType: item.mimeType)
                }
            } catch let error as ImagePreviewError {
                interval.end("result=failed error=\(error)")
                throw error
            } catch is CancellationError {
                interval.end("result=cancelled")
                throw CancellationError()
            } catch {
                interval.end("result=failed error=decodeFailed")
                throw ImagePreviewError.decodeFailed
            }
        case .remoteURL(let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                interval.end("result=failed error=invalidSource")
                throw ImagePreviewError.invalidSource
            }

            do {
                let (data, response) = try await urlSession.data(from: url)
                try Task.checkCancellation()
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode) else {
                    throw ImagePreviewError.networkFailed
                }
                let responseMIME = httpResponse.mimeType.flatMap { $0.isEmpty ? nil : $0 }
                let effectiveMIME = item.mimeType ?? responseMIME
                asset = try await performUtilityWork {
                    try Self.decode(data: data, sourceURL: url, mimeType: effectiveMIME)
                }
            } catch let error as ImagePreviewError {
                interval.end("result=failed error=\(error)")
                throw error
            } catch is CancellationError {
                interval.end("result=cancelled")
                throw CancellationError()
            } catch {
                interval.end("result=failed error=networkFailed")
                throw ImagePreviewError.networkFailed
            }
        case .rawData(let data, let mimeType):
            let effectiveMIME = item.mimeType ?? mimeType
            do {
                asset = try await performUtilityWork {
                    try Self.decode(data: data, sourceURL: nil, mimeType: effectiveMIME)
                }
            } catch {
                interval.end("result=failed error=\(error)")
                throw error
            }
        }

        guard !Task.isCancelled else {
            interval.end("result=cancelled")
            throw CancellationError()
        }
        let decodedCost = Self.decodedPixelCost(for: asset)
        cache.setObject(
            CacheEntry(asset: asset),
            forKey: item.source.cacheKey as NSString,
            cost: decodedCost
        )
        interval.end(
            "result=loaded width=\(Int(asset.pixelSize.width)) " +
            "height=\(Int(asset.pixelSize.height)) bytes=\(decodedCost)"
        )
        return asset
    }

    func preloadAdjacentItems(around items: [ImagePreviewItem], currentIndex: Int) {
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()

        let adjacentIndices = [currentIndex - 1, currentIndex + 1].filter { items.indices.contains($0) }
        for index in adjacentIndices {
            let item = items[index]
            let key = item.source.cacheKey
            guard cache.object(forKey: key as NSString) == nil else { continue }
            preloadTasks[key] = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = try? await self.load(item)
            }
        }
    }

    func cancelCurrentLoad() {
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()
        cache.removeAllObjects()
    }

    private func performUtilityWork<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func sourceKind(_ source: ImagePreviewSource) -> String {
        switch source {
        case .localFile: return "local"
        case .remoteURL: return "remote"
        case .rawData: return "raw"
        }
    }

    private static func decodedPixelCost(for asset: ImagePreviewAsset) -> Int {
        let width = max(1, Int(asset.pixelSize.width.rounded(.up)))
        let height = max(1, Int(asset.pixelSize.height.rounded(.up)))
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow ? Int.max : bytes
    }

    private static func decode(data: Data, sourceURL: URL?, mimeType: String?) throws -> ImagePreviewAsset {
        if let asset = try decodeWithImageIO(data: data) {
            return asset
        }

        if matchesKnownImageType(sourceURL: sourceURL, mimeType: mimeType),
           let image = NSImage(data: data) {
            return ImagePreviewAsset(
                image: image,
                pixelSize: image.size,
                formatIdentifier: sourceURL?.pathExtension.lowercased() ?? (mimeType ?? "unknown"),
                isAnimated: false
            )
        }

        throw ImagePreviewError.unsupportedFormat
    }

    private static func decodeWithImageIO(data: Data) throws -> ImagePreviewAsset? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? CGFloat(cgImage.width)
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? CGFloat(cgImage.height)
        let typeIdentifier = (CGImageSourceGetType(imageSource) as String?) ?? "unknown"
        let image = NSImage(cgImage: cgImage, size: CGSize(width: pixelWidth, height: pixelHeight))

        return ImagePreviewAsset(
            image: image,
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            formatIdentifier: typeIdentifier,
            isAnimated: CGImageSourceGetCount(imageSource) > 1
        )
    }

    private static func matchesKnownImageType(sourceURL: URL?, mimeType: String?) -> Bool {
        if let mimeType, UTType(mimeType: mimeType)?.conforms(to: .image) == true {
            return true
        }

        guard let pathExtension = sourceURL?.pathExtension, !pathExtension.isEmpty else {
            return false
        }

        return UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
    }
}
