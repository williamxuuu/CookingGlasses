import UIKit
import CookingCore

extension CameraFrame {
    static func make(from image: UIImage, timestamp: Date) -> CameraFrame? {
        let maxSide: CGFloat = 640
        let ratio = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = thumbnail.cgImage, let jpeg = thumbnail.jpegData(compressionQuality: 0.55) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        let success = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32)); return true
        }
        guard success else { return nil }
        return .init(timestamp: timestamp, jpegData: jpeg, luminance: pixels)
    }
}
