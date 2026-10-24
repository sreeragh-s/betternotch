import CoreGraphics
import Darwin
import Foundation

/// Load only the reviewed library bundled by scripts/build-native-tools.sh, never a library from the working directory.
public enum WebPEncoder {
    static var libraryURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libwebp.dylib") }
    public static var available: Bool { FileManager.default.fileExists(atPath: libraryURL.path) }
    static func encode(_ image: CGImage, quality: Float, to url: URL) throws {
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw SortError.message("WebP support is not included in this build.") }
        defer { dlclose(library) }
        typealias Encode = @convention(c) (UnsafePointer<UInt8>?, Int32, Int32, Int32, Float, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int
        typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
        guard let encodeSymbol = dlsym(library, "WebPEncodeRGBA"), let freeSymbol = dlsym(library, "WebPFree") else { throw SortError.message("Invalid WebP encoder.") }
        let encode = unsafeBitCast(encodeSymbol, to: Encode.self), free = unsafeBitCast(freeSymbol, to: Free.self)
        let stride = image.width * 4
        var pixels = [UInt8](repeating: 0, count: stride * image.height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SortError.message("Cannot render WebP pixels.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        // WebP expects straight alpha, while Core Graphics renders premultiplied channels.
        for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3]); if alpha > 0 && alpha < 255 { for c in 0..<3 { pixels[index + c] = UInt8(min(255, Int(pixels[index + c]) * 255 / alpha)) } }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let count = pixels.withUnsafeBufferPointer { encode($0.baseAddress, Int32(image.width), Int32(image.height), Int32(stride), quality, &output) }
        guard count > 0, let output else { throw SortError.message("WebP encoding failed.") }
        defer { free(output) }
        try Data(bytes: output, count: count).write(to: url)
    }
}
