import Foundation
import Postbox
import SwiftSignalKit
import Display
import AVFoundation
import ImageIO
import TelegramUIPrivateModule
import TelegramCore

private enum ResourceFileData {
    case data(Data)
    case file(path: String, size: Int)
}

func largestRepresentationForPhoto(_ photo: TelegramMediaImage) -> TelegramMediaImageRepresentation? {
    return photo.representationForDisplayAtSize(CGSize(width: 1280.0, height: 1280.0))
}

private func chatMessagePhotoDatas(postbox: Postbox, photo: TelegramMediaImage, fullRepresentationSize: CGSize = CGSize(width: 1280.0, height: 1280.0), autoFetchFullSize: Bool = false) -> Signal<(Data?, Data?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(photo.representations), let largestRepresentation = photo.representationForDisplayAtSize(fullRepresentationSize) {
        let maybeFullSize = postbox.mediaBox.resourceData(largestRepresentation.resource)
        
        let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((nil, loadedData, true))
            } else {
                let fetchedThumbnail = postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                let fetchedFullSize = postbox.mediaBox.fetchedResource(largestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                
                let thumbnail = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData: Signal<(Data?, Bool), NoError>
                
                if autoFetchFullSize {
                    fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                        let fetchedFullSizeDisposable = fetchedFullSize.start()
                        let fullSizeDisposable = postbox.mediaBox.resourceData(largestRepresentation.resource).start(next: { next in
                            subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedFullSizeDisposable.dispose()
                            fullSizeDisposable.dispose()
                        }
                    }
                } else {
                    fullSizeData = postbox.mediaBox.resourceData(largestRepresentation.resource)
                        |> map { next -> (Data?, Bool) in
                            return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                        }
                }
                
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
        } |> distinctUntilChanged(isEqual: { lhs, rhs in
            if (lhs.0 == nil && lhs.1 == nil) && (rhs.0 == nil && rhs.1 == nil) {
                return true
            } else {
                return false
            }
        })
        
        return signal
    } else {
        return .never()
    }
}

private func chatMessageFileDatas(account: Account, file: TelegramMediaFile, pathExtension: String? = nil, progressive: Bool = false) -> Signal<(Data?, String?, Bool), NoError> {
    let thumbnailResource = smallestImageRepresentation(file.previewRepresentations)?.resource
    let fullSizeResource = file.resource
    
    let maybeFullSize = account.postbox.mediaBox.resourceData(fullSizeResource, pathExtension: pathExtension)
    
    let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, String?, Bool), NoError> in
        if maybeData.complete {
            return .single((nil, maybeData.path, true))
        } else {
            let fetchedThumbnail: Signal<FetchResourceSourceType, NoError>
            if let thumbnailResource = thumbnailResource {
                fetchedThumbnail = account.postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .file))
            } else {
                fetchedThumbnail = .complete()
            }
            
            let thumbnail: Signal<Data?, NoError>
            if let thumbnailResource = thumbnailResource {
                thumbnail = Signal { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource, pathExtension: pathExtension).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
            } else {
                thumbnail = .single(nil)
            }
            
            let fullSizeDataAndPath = account.postbox.mediaBox.resourceData(fullSizeResource, option: !progressive ? .complete(waitUntilFetchStatus: false) : .incremental(waitUntilFetchStatus: false)) |> map { next -> (String?, Bool) in
                return (next.size == 0 ? nil : next.path, next.complete)
            }
            
            return thumbnail |> mapToSignal { thumbnailData in
                return fullSizeDataAndPath |> map { (dataPath, complete) in
                    return (thumbnailData, dataPath, complete)
                }
            }
        }
    } |> filter({ $0.0 != nil || $0.1 != nil })
    
    return signal
}

private let thumbnailGenerationMimeTypes: Set<String> = Set([
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/gif"
])

private func chatMessageImageFileThumbnailDatas(account: Account, file: TelegramMediaFile, pathExtension: String? = nil, progressive: Bool = false) -> Signal<(Data?, String?, Bool), NoError> {
    let thumbnailResource = smallestImageRepresentation(file.previewRepresentations)?.resource
    
    if !thumbnailGenerationMimeTypes.contains(file.mimeType) {
        if let thumbnailResource = thumbnailResource {
            let fetchedThumbnail: Signal<FetchResourceSourceType, NoError> = account.postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .file))
            return Signal { subscriber in
                let fetchedDisposable = fetchedThumbnail.start()
                let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource, pathExtension: pathExtension).start(next: { next in
                    subscriber.putNext(((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), nil, false))
                }, error: subscriber.putError, completed: subscriber.putCompletion)
                
                return ActionDisposable {
                    fetchedDisposable.dispose()
                    thumbnailDisposable.dispose()
                }
            }
        } else {
            return .single((nil, nil, false))
        }
    }
    
    let fullSizeResource: MediaResource = file.resource
    
    let maybeFullSize = account.postbox.mediaBox.cachedResourceRepresentation(fullSizeResource, representation: CachedScaledImageRepresentation(size: CGSize(width: 180.0, height: 180.0), mode: .aspectFit), complete: false)
    
    let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, String?, Bool), NoError> in
        if maybeData.complete {
            return .single((nil, maybeData.path, true))
        } else {
            let fetchedThumbnail: Signal<FetchResourceSourceType, NoError>
            if let thumbnailResource = thumbnailResource {
                fetchedThumbnail = account.postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .file))
            } else {
                fetchedThumbnail = .complete()
            }
            
            let thumbnail: Signal<Data?, NoError>
            if let thumbnailResource = thumbnailResource {
                thumbnail = Signal { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource, pathExtension: pathExtension).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
            } else {
                thumbnail = .single(nil)
            }
            
            let fullSizeDataAndPath = maybeFullSize |> map { next -> (String?, Bool) in
                return (next.size == 0 ? nil : next.path, next.complete)
            }
            
            return thumbnail |> mapToSignal { thumbnailData in
                return fullSizeDataAndPath |> map { (dataPath, complete) in
                    return (thumbnailData, dataPath, complete)
                }
            }
        }
        } |> filter({ $0.0 != nil || $0.1 != nil })
    
    return signal
}

private func chatMessageVideoDatas(postbox: Postbox, file: TelegramMediaFile, thumbnailSize: Bool = false) -> Signal<(Data?, (Data, String)?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(file.previewRepresentations) {
        let thumbnailResource = smallestRepresentation.resource
        let fullSizeResource = file.resource
        
        let maybeFullSize = postbox.mediaBox.cachedResourceRepresentation(fullSizeResource, representation: thumbnailSize ? CachedScaledVideoFirstFrameRepresentation(size: CGSize(width: 160.0, height: 160.0)) : CachedVideoFirstFrameRepresentation(), complete: false)
        
        let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, (Data, String)?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                
                return .single((nil, loadedData == nil ? nil : (loadedData!, maybeData.path), true))
            } else {
                let fetchedThumbnail = postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .video))
                
                let thumbnail = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = postbox.mediaBox.resourceData(thumbnailResource).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                
                let fullSizeDataAndPath = maybeFullSize |> map { next -> ((Data, String)?, Bool) in
                    let data = next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe)
                    return (data == nil ? nil : (data!, next.path), next.complete)
                }
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeDataAndPath |> map { (dataAndPath, complete) in
                        return (thumbnailData, dataAndPath, complete)
                    }
                }
            }
        } |> filter({ $0.0 != nil || $0.1 != nil })
        
        return signal
    } else {
        return .never()
    }
}

private enum Corner: Hashable {
    case TopLeft(Int), TopRight(Int), BottomLeft(Int), BottomRight(Int)
    
    var hashValue: Int {
        switch self {
            case let .TopLeft(radius):
                return radius | (1 << 24)
            case let .TopRight(radius):
                return radius | (2 << 24)
            case let .BottomLeft(radius):
                return radius | (3 << 24)
            case let .BottomRight(radius):
                return radius | (4 << 24)
        }
    }
    
    var radius: Int {
        switch self {
            case let .TopLeft(radius):
                return radius
            case let .TopRight(radius):
                return radius
            case let .BottomLeft(radius):
                return radius
            case let .BottomRight(radius):
                return radius
        }
    }
}

private func ==(lhs: Corner, rhs: Corner) -> Bool {
    switch lhs {
        case let .TopLeft(lhsRadius):
            switch rhs {
                case let .TopLeft(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
        case let .TopRight(lhsRadius):
            switch rhs {
                case let .TopRight(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
        case let .BottomLeft(lhsRadius):
            switch rhs {
                case let .BottomLeft(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
        case let .BottomRight(lhsRadius):
            switch rhs {
                case let .BottomRight(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
    }
}

private enum Tail: Hashable {
    case BottomLeft(Int)
    case BottomRight(Int)
    
    var hashValue: Int {
        switch self {
            case let .BottomLeft(radius):
                return radius | (1 << 24)
            case let .BottomRight(radius):
                return radius | (2 << 24)
        }
    }
    
    var radius: Int {
        switch self {
            case let .BottomLeft(radius):
                return radius
            case let .BottomRight(radius):
                return radius
        }
    }
}

private func ==(lhs: Tail, rhs: Tail) -> Bool {
    switch lhs {
        case let .BottomLeft(lhsRadius):
            switch rhs {
                case let .BottomLeft(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
        case let .BottomRight(lhsRadius):
            switch rhs {
                case let .BottomRight(rhsRadius) where rhsRadius == lhsRadius:
                    return true
                default:
                    return false
            }
    }
}

private var cachedCorners = Atomic<[Corner: DrawingContext]>(value: [:])
private var cachedTails = Atomic<[Tail: DrawingContext]>(value: [:])

private func cornerContext(_ corner: Corner) -> DrawingContext {
    var cached: DrawingContext? = cachedCorners.with {
        return $0[corner]
    }
    
    if let cached = cached {
        return cached
    } else {
        let context = DrawingContext(size: CGSize(width: CGFloat(corner.radius), height: CGFloat(corner.radius)), clear: true)
        
        context.withContext { c in
            c.setBlendMode(.copy)
            c.setFillColor(UIColor.black.cgColor)
            let rect: CGRect
            switch corner {
                case let .TopLeft(radius):
                    rect = CGRect(origin: CGPoint(), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                case let .TopRight(radius):
                    rect = CGRect(origin: CGPoint(x: -CGFloat(radius), y: 0.0), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                case let .BottomLeft(radius):
                    rect = CGRect(origin: CGPoint(x: 0.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                case let .BottomRight(radius):
                    rect = CGRect(origin: CGPoint(x: -CGFloat(radius), y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
            }
            c.fillEllipse(in: rect)
        }
        
        let _ = cachedCorners.modify { current in
            var current = current
            current[corner] = context
            return current
        }
        
        return context
    }
}

private func tailContext(_ tail: Tail) -> DrawingContext {
    var cached: DrawingContext? = cachedTails.with {
        return $0[tail]
    }
    
    if let cached = cached {
        return cached
    } else {
        let context = DrawingContext(size: CGSize(width: CGFloat(tail.radius) + 3.0, height: CGFloat(tail.radius)), clear: true)
        
        context.withContext { c in
            c.setBlendMode(.copy)
            c.setFillColor(UIColor.black.cgColor)
            let rect: CGRect
            switch tail {
                case let .BottomLeft(radius):
                    rect = CGRect(origin: CGPoint(x: 3.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                
                    c.move(to: CGPoint(x: 3.0, y: 1.0))
                    c.addLine(to: CGPoint(x: 3.0, y: 11.0))
                    c.addLine(to: CGPoint(x: 2.3, y: 13.0))
                    c.addLine(to: CGPoint(x: 0.0, y: 16.6))
                    c.addLine(to: CGPoint(x: 4.5, y: 15.5))
                    c.addLine(to: CGPoint(x: 6.5, y: 14.3))
                    c.addLine(to: CGPoint(x: 9.0, y: 12.5))
                    c.closePath()
                    c.fillPath()
                case let .BottomRight(radius):
                    rect = CGRect(origin: CGPoint(x: 3.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                
                    c.translateBy(x: context.size.width / 2.0, y: context.size.height / 2.0)
                    c.scaleBy(x: -1.0, y: 1.0)
                    c.translateBy(x: -context.size.width / 2.0, y: -context.size.height / 2.0)
                
                    c.move(to: CGPoint(x: 3.0, y: 1.0))
                    c.addLine(to: CGPoint(x: 3.0, y: 11.0))
                    c.addLine(to: CGPoint(x: 2.3, y: 13.0))
                    c.addLine(to: CGPoint(x: 0.0, y: 16.6))
                    c.addLine(to: CGPoint(x: 4.5, y: 15.5))
                    c.addLine(to: CGPoint(x: 6.5, y: 14.3))
                    c.addLine(to: CGPoint(x: 9.0, y: 12.5))
                    c.closePath()
                    c.fillPath()
                
                    /*CGContextMoveToPoint(c, 3.0, 0.0)
                    CGContextAddLineToPoint(c, 3.0, 8.7)
                    CGContextAddLineToPoint(c, 2.0, 11.7)
                    CGContextAddLineToPoint(c, 1.5, 12.7)
                    CGContextAddLineToPoint(c, 0.8, 13.7)
                    CGContextAddLineToPoint(c, 0.2, 14.4)
                    CGContextAddLineToPoint(c, 3.5, 13.8)
                    CGContextAddLineToPoint(c, 5.0, 13.2)
                    CGContextAddLineToPoint(c, 3.0 + CGFloat(radius) - 9.5, 11.5)
                    CGContextClosePath(c)
                    CGContextFillPath(c)*/
            }
            c.fillEllipse(in: rect)
        }
        
        let _ = cachedTails.modify { current in
            var current = current
            current[tail] = context
            return current
        }
        return context
    }
}

private func addCorners(_ context: DrawingContext, arguments: TransformImageArguments) {
    let corners = arguments.corners
    let drawingRect = arguments.drawingRect
    if case let .Corner(radius) = corners.topLeft, radius > CGFloat.ulpOfOne {
        let corner = cornerContext(.TopLeft(Int(radius)))
        context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.minY))
    }
    
    if case let .Corner(radius) = corners.topRight, radius > CGFloat.ulpOfOne {
        let corner = cornerContext(.TopRight(Int(radius)))
        context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.minY))
    }
    
    switch corners.bottomLeft {
        case let .Corner(radius):
            if radius > CGFloat.ulpOfOne {
                let corner = cornerContext(.BottomLeft(Int(radius)))
                context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.maxY - radius))
            }
        case let .Tail(radius, enabled):
            if radius > CGFloat.ulpOfOne {
                if enabled {
                    let tail = tailContext(.BottomLeft(Int(radius)))
                    let color = context.colorAt(CGPoint(x: drawingRect.minX, y: drawingRect.maxY - 1.0))
                    context.withContext { c in
                        c.clear(CGRect(x: drawingRect.minX - 3.0, y: 0.0, width: 3.0, height: drawingRect.maxY - 6.0))
                        c.setFillColor(color.cgColor)
                        c.fill(CGRect(x: 0.0, y: drawingRect.maxY - 6.0, width: 3.0, height: 6.0))
                    }
                    context.blt(tail, at: CGPoint(x: drawingRect.minX - 3.0, y: drawingRect.maxY - radius))
                } else {
                    let corner = cornerContext(.BottomLeft(Int(radius)))
                    context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.maxY - radius))
                }
            }
        
    }
    
    switch corners.bottomRight {
        case let .Corner(radius):
            if radius > CGFloat.ulpOfOne {
                let corner = cornerContext(.BottomRight(Int(radius)))
                context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.maxY - radius))
            }
        case let .Tail(radius, enabled):
            if radius > CGFloat.ulpOfOne {
                if enabled {
                    let tail = tailContext(.BottomRight(Int(radius)))
                    let color = context.colorAt(CGPoint(x: drawingRect.maxX - 1.0, y: drawingRect.maxY - 1.0))
                    context.withContext { c in
                        c.clear(CGRect(x: drawingRect.maxX, y: 0.0, width: 3.0, height: drawingRect.maxY - 6.0))
                        c.setFillColor(color.cgColor)
                        c.fill(CGRect(x: drawingRect.maxX, y: drawingRect.maxY - 6.0, width: 3.0, height: 6.0))
                    }
                    context.blt(tail, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.maxY - radius))
                } else {
                    let corner = cornerContext(.BottomRight(Int(radius)))
                    context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.maxY - radius))
                }
            }
    }
}

func rawMessagePhoto(postbox: Postbox, photo: TelegramMediaImage) -> Signal<UIImage?, NoError> {
    return chatMessagePhotoDatas(postbox: postbox, photo: photo, autoFetchFullSize: true)
        |> map { (thumbnailData, fullSizeData, fullSizeComplete) -> UIImage? in
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    return UIImage(data: fullSizeData)?.precomposed()
                }
            }
            if let thumbnailData = thumbnailData {
                return UIImage(data: thumbnailData)?.precomposed()
            }
            return nil
        }
}

func chatMessagePhoto(postbox: Postbox, photo: TelegramMediaImage) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: postbox, photo: photo)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if thumbnailImage == nil && fullSizeImage == nil {
                    c.setFillColor(UIColor.white.cgColor)
                    c.fill(fittedRect)
                } else {
                    if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                        let blurSourceImage = thumbnailImage ?? fullSizeImage
                        
                        if let fullSizeImage = blurSourceImage {
                            let thumbnailSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height)
                            let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 74.0, height: 74.0))
                            let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                            thumbnailContext.withFlippedContext { c in
                                c.interpolationQuality = .none
                                c.draw(fullSizeImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                            }
                            telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            
                            if let blurredImage = thumbnailContext.generateImage() {
                                let filledSize = thumbnailSize.aspectFilled(arguments.drawingRect.size)
                                c.interpolationQuality = .medium
                                c.draw(blurredImage.cgImage!, in: CGRect(origin: CGPoint(x:arguments.drawingRect.minX + (arguments.drawingRect.width - filledSize.width) / 2.0, y: arguments.drawingRect.minY + (arguments.drawingRect.height - filledSize.height) / 2.0), size: filledSize))
                                c.setBlendMode(.normal)
                                c.setFillColor(UIColor(white: 1.0, alpha: 0.5).cgColor)
                                c.fill(arguments.drawingRect)
                                c.setBlendMode(.copy)
                            }
                        } else {
                            c.fill(arguments.drawingRect)
                        }
                    }
                    
                    c.setBlendMode(.copy)
                    if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                        c.interpolationQuality = .low
                        c.draw(cgImage, in: fittedRect)
                        c.setBlendMode(.normal)
                    }
                    
                    if let fullSizeImage = fullSizeImage {
                        c.interpolationQuality = .medium
                        c.draw(fullSizeImage, in: fittedRect)
                    }
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

private func chatMessagePhotoThumbnailDatas(account: Account, photo: TelegramMediaImage) -> Signal<(Data?, Data?, Bool), NoError> {
    let fullRepresentationSize: CGSize = CGSize(width: 1280.0, height: 1280.0)
    if let smallestRepresentation = smallestImageRepresentation(photo.representations), let largestRepresentation = photo.representationForDisplayAtSize(fullRepresentationSize) {
        
        let maybeFullSize = account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 180.0, height: 180.0), mode: .aspectFit), complete: false)
        
        let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((nil, loadedData, true))
            } else {
                let fetchedThumbnail = account.postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                
                let thumbnail = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData: Signal<(Data?, Bool), NoError> = maybeFullSize
                    |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    }
                
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
        } |> filter({ $0.0 != nil || $0.1 != nil })
        
        return signal
    } else {
        return .never()
    }
}

func chatMessagePhotoThumbnail(account: Account, photo: TelegramMediaImage) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoThumbnailDatas(account: account, photo: photo)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(UIColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatMessageVideoThumbnail(account: Account, file: TelegramMediaFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageVideoDatas(postbox: account.postbox, file: file, thumbnailSize: true)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData?.0 {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(UIColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatSecretPhoto(account: Account, photo: TelegramMediaImage) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, photo: photo)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var blurredImage: UIImage?
            
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        let thumbnailSize = CGSize(width: image.width, height: image.height)
                        let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                        let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                        thumbnailContext.withFlippedContext { c in
                            c.interpolationQuality = .none
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                        }
                        telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                        
                        let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                        let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                        thumbnailContext2.withFlippedContext { c in
                            c.interpolationQuality = .none
                            if let image = thumbnailContext.generateImage()?.cgImage {
                                c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                            }
                        }
                        telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                        
                        blurredImage = thumbnailContext2.generateImage()
                    }
                }/* else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }*/
            }
            
            if blurredImage == nil {
                if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    let thumbnailSize = CGSize(width: image.width, height: image.height)
                    let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withFlippedContext { c in
                        c.interpolationQuality = .none
                        c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    
                    let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                    let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                    thumbnailContext2.withFlippedContext { c in
                        c.interpolationQuality = .none
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                        }
                    }
                    telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                    
                    blurredImage = thumbnailContext2.generateImage()
                }
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(UIColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredImage = blurredImage, let cgImage = blurredImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                }
                
                if !arguments.insets.left.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(), size: CGSize(width: arguments.insets.left, height: context.size.height)))
                }
                if !arguments.insets.right.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(x: context.size.width - arguments.insets.right, y: 0.0), size: CGSize(width: arguments.insets.right, height: context.size.height)))
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func mediaGridMessagePhoto(account: Account, photo: TelegramMediaImage) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, photo: photo, fullRepresentationSize: CGSize(width: 127.0, height: 127.0), autoFetchFullSize: true)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            assertNotOnMainThread()
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != arguments.imageSize {
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func gifPaneVideoThumbnail(account: Account, video: TelegramMediaFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    if let smallestRepresentation = smallestImageRepresentation(video.previewRepresentations) {
        let thumbnailResource = smallestRepresentation.resource
        
        let thumbnail = Signal<MediaResourceData, NoError> { subscriber in
            let data = account.postbox.mediaBox.resourceData(thumbnailResource).start(next: { data in
                subscriber.putNext(data)
            }, completed: {
                subscriber.putCompletion()
            })
            let fetched = account.postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .video)).start()
            return ActionDisposable {
                data.dispose()
                fetched.dispose()
            }
        }
        
        return thumbnail
            |> map { data in
                let thumbnailData = try? Data(contentsOf: URL(fileURLWithPath: data.path))
                return { arguments in
                    let context = DrawingContext(size: arguments.drawingSize, clear: true)
                    let drawingRect = arguments.drawingRect
                    let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
                    let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                    
                    var thumbnailImage: CGImage?
                    if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                        thumbnailImage = image
                    }
                    
                    var blurredThumbnailImage: UIImage?
                    if let thumbnailImage = thumbnailImage {
                        let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                        let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                        let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                        thumbnailContext.withFlippedContext { c in
                            c.interpolationQuality = .none
                            c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                        }
                        telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                        
                        blurredThumbnailImage = thumbnailContext.generateImage()
                    }
                    
                    context.withFlippedContext { c in
                        c.setBlendMode(.copy)
                        if arguments.boundingSize != arguments.imageSize {
                            c.fill(arguments.drawingRect)
                        }
                        
                        c.setBlendMode(.copy)
                        if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                            c.interpolationQuality = .low
                            c.draw(cgImage, in: fittedRect)
                            c.setBlendMode(.normal)
                        }
                    }
                    
                    addCorners(context, arguments: arguments)
                    
                    return context
                }
            }
    } else {
        return .never()
    }
}

func mediaGridMessageVideo(postbox: Postbox, video: TelegramMediaFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageVideoDatas(postbox: postbox, file: video)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            assertNotOnMainThread()
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            if fittedSize.width < drawingRect.size.width && fittedSize.width >= drawingRect.size.width - 2.0 {
                fittedSize.width = drawingRect.size.width
            }
            if fittedSize.height < drawingRect.size.height && fittedSize.height >= drawingRect.size.height - 2.0 {
                fittedSize.height = drawingRect.size.height
            }
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    //options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    //options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData.0 as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData.0 as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != arguments.imageSize {
                    switch arguments.resizeMode {
                        case .blurBackground:
                            let blurSourceImage = thumbnailImage ?? fullSizeImage
                            
                            if let fullSizeImage = blurSourceImage {
                                let thumbnailSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height)
                                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 74.0, height: 74.0))
                                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                                thumbnailContext.withFlippedContext { c in
                                    c.interpolationQuality = .none
                                    c.draw(fullSizeImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                                }
                                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                                
                                if let blurredImage = thumbnailContext.generateImage() {
                                    let filledSize = thumbnailSize.aspectFilled(arguments.drawingRect.size)
                                    c.interpolationQuality = .medium
                                    c.draw(blurredImage.cgImage!, in: CGRect(origin: CGPoint(x: arguments.drawingRect.minX + (arguments.drawingRect.width - filledSize.width) / 2.0, y: arguments.drawingRect.minY + (arguments.drawingRect.height - filledSize.height) / 2.0), size: filledSize))
                                    c.setBlendMode(.normal)
                                    c.setFillColor(UIColor(white: 1.0, alpha: 0.5).cgColor)
                                    c.fill(arguments.drawingRect)
                                    c.setBlendMode(.copy)
                                }
                            } else {
                                c.fill(arguments.drawingRect)
                            }
                        case let .fill(color):
                            c.setFillColor(color.cgColor)
                            c.fill(arguments.drawingRect)
                    }
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatMessagePhotoStatus(account: Account, photo: TelegramMediaImage) -> Signal<MediaResourceStatus, NoError> {
    if let largestRepresentation = largestRepresentationForPhoto(photo) {
        return account.postbox.mediaBox.resourceStatus(largestRepresentation.resource)
    } else {
        return .never()
    }
}

func chatMessagePhotoInteractiveFetched(account: Account, photo: TelegramMediaImage) -> Signal<FetchResourceSourceType, NoError> {
    if let largestRepresentation = largestRepresentationForPhoto(photo) {
        return account.postbox.mediaBox.fetchedResource(largestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
    } else {
        return .never()
    }
}

func chatMessagePhotoCancelInteractiveFetch(account: Account, photo: TelegramMediaImage) {
    if let largestRepresentation = largestRepresentationForPhoto(photo) {
        return account.postbox.mediaBox.cancelInteractiveResourceFetch(largestRepresentation.resource)
    }
}

func chatMessageWebFileInteractiveFetched(account: Account, image: TelegramMediaWebFile) -> Signal<FetchResourceSourceType, NoError> {
    return account.postbox.mediaBox.fetchedResource(image.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
}

func chatMessageWebFileCancelInteractiveFetch(account: Account, image: TelegramMediaWebFile) {
    return account.postbox.mediaBox.cancelInteractiveResourceFetch(image.resource)
}

func chatWebpageSnippetPhotoData(account: Account, photo: TelegramMediaImage) -> Signal<Data?, NoError> {
    if let closestRepresentation = photo.representationForDisplayAtSize(CGSize(width: 120.0, height: 120.0)) {
        let resourceData = account.postbox.mediaBox.resourceData(closestRepresentation.resource) |> map { next in
            return next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe)
        }
        
        return Signal { subscriber in
            let disposable = DisposableSet()
            disposable.add(resourceData.start(next: { data in
                subscriber.putNext(data)
            }, error: { error in
                subscriber.putError(error)
            }, completed: {
                subscriber.putCompletion()
            }))
            disposable.add(account.postbox.mediaBox.fetchedResource(closestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image)).start())
            return disposable
        }
    } else {
        return .never()
    }
}

func chatWebpageSnippetPhoto(account: Account, photo: TelegramMediaImage) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatWebpageSnippetPhotoData(account: account, photo: photo)
    
    return signal |> map { fullSizeData in
        return { arguments in
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                let options = NSMutableDictionary()
                if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                    fullSizeImage = image
                }
            }
            
            if let fullSizeImage = fullSizeImage {
                let context = DrawingContext(size: arguments.drawingSize, clear: true)
                
                let fittedSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height).aspectFilled(arguments.boundingSize)
                let drawingRect = arguments.drawingRect
                
                let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    if arguments.boundingSize.width > arguments.imageSize.width || arguments.boundingSize.height > arguments.imageSize.height {
                        c.fill(arguments.drawingRect)
                    }
                    
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
                
                addCorners(context, arguments: arguments)
                
                return context
            } else {
                return nil
            }
        }
    }
}

func chatMessageVideo(postbox: Postbox, video: TelegramMediaFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return mediaGridMessageVideo(postbox: postbox, video: video)
}

private func chatSecretMessageVideoData(account: Account, file: TelegramMediaFile) -> Signal<Data?, NoError> {
    if let smallestRepresentation = smallestImageRepresentation(file.previewRepresentations) {
        let thumbnailResource = smallestRepresentation.resource
        
        let fetchedThumbnail = account.postbox.mediaBox.fetchedResource(thumbnailResource, tag: TelegramMediaResourceFetchTag(statsCategory: .video))
        
        let thumbnail = Signal<Data?, NoError> { subscriber in
            let fetchedDisposable = fetchedThumbnail.start()
            let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource).start(next: { next in
                subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
            }, error: subscriber.putError, completed: subscriber.putCompletion)
            
            return ActionDisposable {
                fetchedDisposable.dispose()
                thumbnailDisposable.dispose()
            }
        }
        return thumbnail
    } else {
        return .single(nil)
    }
}

func chatSecretMessageVideo(account: Account, video: TelegramMediaFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatSecretMessageVideoData(account: account, file: video)
    
    return signal |> map { thumbnailData in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            if arguments.drawingSize.width.isLessThanOrEqualTo(0.0) || arguments.drawingSize.height.isLessThanOrEqualTo(0.0) {
                return context
            }
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            /*var fullSizeImage: CGImage?
            if let fullSizeDataAndPath = fullSizeDataAndPath {
                if fullSizeComplete {
                    if video.mimeType.hasPrefix("video/") {
                        let tempFilePath = NSTemporaryDirectory() + "\(arc4random()).mov"
                        
                        _ = try? FileManager.default.removeItem(atPath: tempFilePath)
                        _ = try? FileManager.default.linkItem(atPath: fullSizeDataAndPath.1, toPath: tempFilePath)
                        
                        let asset = AVAsset(url: URL(fileURLWithPath: tempFilePath))
                        let imageGenerator = AVAssetImageGenerator(asset: asset)
                        imageGenerator.maximumSize = CGSize(width: 800.0, height: 800.0)
                        imageGenerator.appliesPreferredTrackTransform = true
                        if let image = try? imageGenerator.copyCGImage(at: CMTime(seconds: 0.0, preferredTimescale: asset.duration.timescale), actualTime: nil) {
                            fullSizeImage = image
                        }
                    }
                    /*let options: [NSString: NSObject] = [
                     kCGImageSourceThumbnailMaxPixelSize: max(fittedSize.width * context.scale, fittedSize.height * context.scale),
                     kCGImageSourceCreateThumbnailFromImageAlways: true
                     ]
                     if let imageSource = CGImageSourceCreateWithData(fullSizeData, nil), image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) {
                     fullSizeImage = image
                     }*/
                } else {
                    /*let imageSource = CGImageSourceCreateIncremental(nil)
                     CGImageSourceUpdateData(imageSource, fullSizeData as CFDataRef, fullSizeData.length >= fullTotalSize)
                     
                     var options: [NSString : NSObject!] = [:]
                     options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                     if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionaryRef) {
                     fullSizeImage = image
                     }*/
                }
            }*/
            var blurredImage: UIImage?
            
            if blurredImage == nil {
                if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    let thumbnailSize = CGSize(width: image.width, height: image.height)
                    let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withFlippedContext { c in
                        c.interpolationQuality = .none
                        c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    
                    let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                    let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                    thumbnailContext2.withFlippedContext { c in
                        c.interpolationQuality = .none
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                        }
                    }
                    telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                    
                    blurredImage = thumbnailContext2.generateImage()
                }
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(UIColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredImage = blurredImage, let cgImage = blurredImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                }
                
                if !arguments.insets.left.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(), size: CGSize(width: arguments.insets.left, height: context.size.height)))
                }
                if !arguments.insets.right.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(x: context.size.width - arguments.insets.right, y: 0.0), size: CGSize(width: arguments.insets.right, height: context.size.height)))
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatMessageImageFile(account: Account, file: TelegramMediaFile, thumbnail: Bool) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal: Signal<(Data?, String?, Bool), NoError>
    if thumbnail {
        signal = chatMessageImageFileThumbnailDatas(account: account, file: file)
    } else {
        signal = chatMessageFileDatas(account: account, file: file, progressive: false)
    }
    
    return signal |> map { (thumbnailData, fullSizePath, fullSizeComplete) in
        return { arguments in
            assertNotOnMainThread()
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize: CGSize
            if thumbnail {
                fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize)
            } else {
                fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            }
            
            var fullSizeImage: CGImage?
            if let fullSizePath = fullSizePath {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: fullSizePath) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) {
                        fullSizeImage = image
                        if thumbnail {
                            fittedSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height)).aspectFilled(arguments.boundingSize)
                        }
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
                if thumbnail {
                    fittedSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height)).aspectFilled(arguments.boundingSize)
                }
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != fittedSize {
                    c.fill(drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.setBlendMode(.normal)
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

private func avatarGalleryPhotoDatas(account: Account, representations: [TelegramMediaImageRepresentation], autoFetchFullSize: Bool = false) -> Signal<(Data?, Data?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(representations), let largestRepresentation = largestImageRepresentation(representations) {
        let maybeFullSize = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
        
        let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((nil, loadedData, true))
            } else {
                let fetchedThumbnail = account.postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                let fetchedFullSize = account.postbox.mediaBox.fetchedResource(largestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                
                let thumbnail = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData: Signal<(Data?, Bool), NoError>
                
                if autoFetchFullSize {
                    fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                        let fetchedFullSizeDisposable = fetchedFullSize.start()
                        let fullSizeDisposable = account.postbox.mediaBox.resourceData(largestRepresentation.resource).start(next: { next in
                            subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedFullSizeDisposable.dispose()
                            fullSizeDisposable.dispose()
                        }
                    }
                } else {
                    fullSizeData = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                        |> map { next -> (Data?, Bool) in
                            return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    }
                }
                
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
            } |> filter({ $0.0 != nil || $0.1 != nil })
        
        return signal
    } else {
        return .never()
    }
}

func chatAvatarGalleryPhoto(account: Account, representations: [TelegramMediaImageRepresentation], autoFetchFullSize: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = avatarGalleryPhotoDatas(account: account, representations: representations, autoFetchFullSize: autoFetchFullSize)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(UIColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

private func builtinWallpaperData() -> Signal<UIImage, NoError> {
    return Signal { subscriber in
        if let filePath = frameworkBundle.path(forResource: "ChatWallpaperBuiltin0", ofType: "jpg"), let image = UIImage(contentsOfFile: filePath) {
            subscriber.putNext(image)
        }
        subscriber.putCompletion()
        
        return EmptyDisposable
    } |> runOn(Queue.concurrentDefaultQueue())
}

func settingsBuiltinWallpaperImage(account: Account) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return builtinWallpaperData() |> map { fullSizeImage in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = fullSizeImage.size.aspectFilled(drawingRect.size)
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if let fullSizeImage = fullSizeImage.cgImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatMapSnapshotData(account: Account, resource: MapSnapshotMediaResource) -> Signal<Data?, NoError> {
    return Signal<Data?, NoError> { subscriber in
        let fetchedDisposable = account.postbox.mediaBox.fetchedResource(resource, tag: nil).start()
        let dataDisposable = account.postbox.mediaBox.resourceData(resource).start(next: { next in
            if next.size != 0 {
                subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
            }
        }, error: subscriber.putError, completed: subscriber.putCompletion)
        
        return ActionDisposable {
            fetchedDisposable.dispose()
            dataDisposable.dispose()
        }
    }
}

private let locationPinImage = UIImage(named: "ModernMessageLocationPin")?.precomposed()

func chatMapSnapshotImage(account: Account, resource: MapSnapshotMediaResource) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMapSnapshotData(account: account, resource: resource)
    
    return signal |> map { fullSizeData in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                let options = NSMutableDictionary()
                options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                    fullSizeImage = image
                }
                
                if let fullSizeImage = fullSizeImage {
                    let drawingRect = arguments.drawingRect
                    var fittedSize = CGSize(width: CGFloat(fullSizeImage.width), height: CGFloat(fullSizeImage.height)).aspectFilled(drawingRect.size)
                    if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                        fittedSize.width = arguments.boundingSize.width
                    }
                    if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                        fittedSize.height = arguments.boundingSize.height
                    }
                    
                    let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                    
                    context.withFlippedContext { c in
                        c.setBlendMode(.copy)
                        if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                            c.fill(arguments.drawingRect)
                        }
                        
                        c.setBlendMode(.copy)
                        
                        c.interpolationQuality = .medium
                        c.draw(fullSizeImage, in: fittedRect)
                        
                        c.setBlendMode(.normal)
                        
                        if let locationPinImage = locationPinImage {
                            c.draw(locationPinImage.cgImage!, in: CGRect(origin: CGPoint(x: floor((arguments.drawingSize.width - locationPinImage.size.width) / 2.0), y: floor((arguments.drawingSize.height - locationPinImage.size.height) / 2.0) - 5.0), size: locationPinImage.size))
                        }
                    }
                } else {
                    context.withFlippedContext { c in
                        c.setBlendMode(.copy)
                        c.setFillColor(UIColor.white.cgColor)
                        c.fill(arguments.drawingRect)
                        
                        c.setBlendMode(.normal)
                        
                        if let locationPinImage = locationPinImage {
                            c.draw(locationPinImage.cgImage!, in: CGRect(origin: CGPoint(x: floor((arguments.drawingSize.width - locationPinImage.size.width) / 2.0), y: floor((arguments.drawingSize.height - locationPinImage.size.height) / 2.0) - 5.0), size: locationPinImage.size))
                        }
                    }
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

func chatWebFileImage(account: Account, file: TelegramMediaWebFile) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return account.postbox.mediaBox.resourceData(file.resource)
        |> map { fullSizeData in
            return { arguments in
                let context = DrawingContext(size: arguments.drawingSize, clear: true)
                
                var fullSizeImage: CGImage?
                if fullSizeData.complete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: fullSizeData.path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                    
                    if let fullSizeImage = fullSizeImage {
                        let drawingRect = arguments.drawingRect
                        var fittedSize = CGSize(width: CGFloat(fullSizeImage.width), height: CGFloat(fullSizeImage.height)).aspectFilled(drawingRect.size)
                        if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                            fittedSize.width = arguments.boundingSize.width
                        }
                        if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                            fittedSize.height = arguments.boundingSize.height
                        }
                        
                        let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                        
                        context.withFlippedContext { c in
                            c.setBlendMode(.copy)
                            if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                                c.fill(arguments.drawingRect)
                            }
                            
                            c.setBlendMode(.copy)
                            
                            c.interpolationQuality = .medium
                            c.draw(fullSizeImage, in: fittedRect)
                            
                            c.setBlendMode(.normal)
                        }
                    } else {
                        context.withFlippedContext { c in
                            c.setBlendMode(.copy)
                            c.setFillColor(UIColor.white.cgColor)
                            c.fill(arguments.drawingRect)
                            
                            c.setBlendMode(.normal)
                        }
                    }
                }
                
                addCorners(context, arguments: arguments)
                
                return context
            }
    }
}

private let precomposedSmallAlbumArt = Atomic<UIImage?>(value: nil)

private func albumArtThumbnailData(postbox: Postbox, thumbnail: MediaResource) -> Signal<(Data?), NoError> {
    let thumbnailResource = postbox.mediaBox.resourceData(thumbnail)
    
    let signal = thumbnailResource |> take(1) |> mapToSignal { maybeData -> Signal<(Data?), NoError> in
        if maybeData.complete {
            let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
            return .single((loadedData))
        } else {
            let fetchedThumbnail = postbox.mediaBox.fetchedResource(thumbnail, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
            
            let thumbnail = Signal<Data?, NoError> { subscriber in
                let fetchedDisposable = fetchedThumbnail.start()
                let thumbnailDisposable = thumbnailResource.start(next: { next in
                    subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                }, error: subscriber.putError, completed: subscriber.putCompletion)
                
                return ActionDisposable {
                    fetchedDisposable.dispose()
                    thumbnailDisposable.dispose()
                }
            }
            
            return thumbnail
        }
    } |> distinctUntilChanged(isEqual: { lhs, rhs in
        if lhs == nil && rhs == nil {
            return true
        } else {
            return false
        }
    })
    
    return signal
}

private func albumArtFullSizeDatas(postbox: Postbox, thumbnail: MediaResource, fullSize: MediaResource, autoFetchFullSize: Bool = true) -> Signal<(Data?, Data?, Bool), NoError> {
    let fullSizeResource = postbox.mediaBox.resourceData(fullSize)
    let thumbnailResource = postbox.mediaBox.resourceData(thumbnail)
        
    let signal = fullSizeResource |> take(1) |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
        if maybeData.complete {
            let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
            return .single((nil, loadedData, true))
        } else {
            let fetchedThumbnail = postbox.mediaBox.fetchedResource(thumbnail, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
            let fetchedFullSize = postbox.mediaBox.fetchedResource(fullSize, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
            
            let thumbnail = Signal<Data?, NoError> { subscriber in
                let fetchedDisposable = fetchedThumbnail.start()
                let thumbnailDisposable = thumbnailResource.start(next: { next in
                    subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                }, error: subscriber.putError, completed: subscriber.putCompletion)
                
                return ActionDisposable {
                    fetchedDisposable.dispose()
                    thumbnailDisposable.dispose()
                }
            }
            
            let fullSizeData: Signal<(Data?, Bool), NoError>
            
            if autoFetchFullSize {
                fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                    let fetchedFullSizeDisposable = fetchedFullSize.start()
                    let fullSizeDisposable = fullSizeResource.start(next: { next in
                        subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedFullSizeDisposable.dispose()
                        fullSizeDisposable.dispose()
                    }
                }
            } else {
                fullSizeData = fullSizeResource
                |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                }
            }
            
            
            return thumbnail |> mapToSignal { thumbnailData in
                return fullSizeData |> map { (fullSizeData, complete) in
                    return (thumbnailData, fullSizeData, complete)
                }
            }
        }
        } |> distinctUntilChanged(isEqual: { lhs, rhs in
            if (lhs.0 == nil && lhs.1 == nil) && (rhs.0 == nil && rhs.1 == nil) {
                return true
            } else {
                return false
            }
        })
    
    return signal
}

private func drawAlbumArtPlaceholder(into c: CGContext, arguments: TransformImageArguments, thumbnail: Bool) {
    c.setBlendMode(.copy)
    c.setFillColor(UIColor(rgb: 0xeeeeee).cgColor)
    c.fill(arguments.drawingRect)
    
    c.setBlendMode(.normal)
    
    if thumbnail {
        var image: UIImage?
        let precomposed = precomposedSmallAlbumArt.with { $0 }
        if let precomposed = precomposed {
            image = precomposed
        } else {
            if let sourceImage = UIImage(bundleImageName: "GlobalMusicPlayer/AlbumArtPlaceholder"), let cgImage = sourceImage.cgImage {
                
                let fittedSize = sourceImage.size.aspectFitted(CGSize(width: 28.0, height: 28.0))
                
                image = generateImage(fittedSize, contextGenerator: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    context.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
                })
                
                if let image = image {
                    let _ = precomposedSmallAlbumArt.swap(image)
                }
            }
        }
        if let image = image, let cgImage = image.cgImage {
            c.draw(cgImage, in: CGRect(origin: CGPoint(x: floor(arguments.drawingRect.size.width - image.size.width) / 2.0, y: floor(arguments.drawingRect.size.height - image.size.height) / 2.0), size: image.size))
        }
    } else {
        if let sourceImage = UIImage(bundleImageName: "GlobalMusicPlayer/AlbumArtPlaceholder"), let cgImage = sourceImage.cgImage {
            let fittedSize = sourceImage.size.aspectFitted(CGSize(width: floor(arguments.drawingRect.size.width * 0.66), height: floor(arguments.drawingRect.size.width * 0.66)))
            
            c.draw(cgImage, in: CGRect(origin: CGPoint(x: floor(arguments.drawingRect.size.width - fittedSize.width) / 2.0, y: floor(arguments.drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize))
        }
    }
}

func playerAlbumArt(postbox: Postbox, albumArt: SharedMediaPlaybackAlbumArt?, thumbnail: Bool) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    if let albumArt = albumArt {
        if thumbnail {
            return albumArtThumbnailData(postbox: postbox, thumbnail: albumArt.thumbnailResource) |> map { thumbnailData in
                return { arguments in
                    let context = DrawingContext(size: arguments.drawingSize, clear: true)
                    
                    var sourceImage: UIImage?
                    if let thumbnailData = thumbnailData, let image = UIImage(data: thumbnailData) {
                        sourceImage = image
                    }
                    
                    if let sourceImage = sourceImage, let cgImage = sourceImage.cgImage {
                        let imageSize = sourceImage.size.aspectFilled(arguments.drawingRect.size)
                        context.withFlippedContext { c in
                            c.draw(cgImage, in: CGRect(origin: CGPoint(x: floor((arguments.drawingRect.size.width - imageSize.width) / 2.0), y: floor((arguments.drawingRect.size.height - imageSize.height) / 2.0)), size: imageSize))
                        }
                    } else {
                        context.withFlippedContext { c in
                            drawAlbumArtPlaceholder(into: c, arguments: arguments, thumbnail: thumbnail)
                        }
                    }
                    
                    addCorners(context, arguments: arguments)
                    
                    return context
                }
            }
        } else {
            return albumArtFullSizeDatas(postbox: postbox, thumbnail: albumArt.thumbnailResource, fullSize: albumArt.fullSizeResource) |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
                return { arguments in
                    let context = DrawingContext(size: arguments.drawingSize, clear: true)
                    
                    var sourceImage: UIImage?
                    if fullSizeComplete, let fullSizeData = fullSizeData, let image = UIImage(data: fullSizeData) {
                        sourceImage = image
                    } else if let thumbnailData = thumbnailData, let image = UIImage(data: thumbnailData) {
                        sourceImage = image
                    }
                    
                    if let sourceImage = sourceImage, let cgImage = sourceImage.cgImage {
                        let imageSize = sourceImage.size.aspectFilled(arguments.drawingRect.size)
                        context.withFlippedContext { c in
                            c.draw(cgImage, in: CGRect(origin: CGPoint(x: floor((arguments.drawingRect.size.width - imageSize.width) / 2.0), y: floor((arguments.drawingRect.size.height - imageSize.height) / 2.0)), size: imageSize))
                        }
                    } else {
                        context.withFlippedContext { c in
                            drawAlbumArtPlaceholder(into: c, arguments: arguments, thumbnail: thumbnail)
                        }
                    }
                    
                    addCorners(context, arguments: arguments)
                    
                    return context
                }
            }
        }
    } else {
        return .single({ arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
        
            context.withFlippedContext { c in
                drawAlbumArtPlaceholder(into: c, arguments: arguments, thumbnail: thumbnail)
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        })
    }
}
