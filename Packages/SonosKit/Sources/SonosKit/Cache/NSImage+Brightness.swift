/// PlatformImage+Brightness.swift — Average perceived luminance for a
/// PlatformImage, used by Vis surfaces to adapt overlays to the artwork.
import CoreGraphics

#if canImport(AppKit)
import AppKit

public extension NSImage {
    func averagePerceivedLuminance() -> Double {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0.5
        }
        return cgImage.averagePerceivedLuminance()
    }
}

#elseif canImport(UIKit)
import UIKit

public extension UIImage {
    func averagePerceivedLuminance() -> Double {
        guard let cgImage = self.cgImage else { return 0.5 }
        return cgImage.averagePerceivedLuminance()
    }
}
#endif

private extension CGImage {
    func averagePerceivedLuminance() -> Double {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return 0.5
        }
        context.interpolationQuality = .medium
        context.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
