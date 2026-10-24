import Darwin
import Foundation
import UniformTypeIdentifiers

enum ScreenshotDetector {
    static let captureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    static func isScreenshot(_ file: FileDescriptor) -> Bool {
        guard UTType(file.typeIdentifier)?.conforms(to: .image) == true else { return false }
        if hasCaptureMetadata(file.url) { return true }
        // A conservative fallback for captures whose metadata was lost during copying.
        // ICU's whitespace class includes the narrow no-break space in macOS filenames.
        let stem = file.url.deletingPathExtension().lastPathComponent
        let pattern = #"^(?:screenshot|screen[\s_-]+shot|screen[\s_-]+capture)[\s_-]+\d{4}[-.]\d{2}[-.]\d{2}(?:[\s_-]+at)?[\s_-]+\d{1,2}[.:]\d{2}[.:]\d{2}(?:\s*[ap]m)?(?:\s*(?:\(\d+\)|-\d+))?$"#
        return stem.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasCaptureMetadata(_ url: URL) -> Bool {
        // Read the bounded on-disk attribute directly; Spotlight need not have indexed this file.
        var bytes = [UInt8](repeating: 0, count: 256)
        let length = bytes.withUnsafeMutableBytes { buffer in
            getxattr(url.path, captureAttribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        guard length > 0,
              let value = try? PropertyListSerialization.propertyList(from: Data(bytes.prefix(length)), options: [], format: nil) as? NSNumber else { return false }
        return value.boolValue
    }
}
