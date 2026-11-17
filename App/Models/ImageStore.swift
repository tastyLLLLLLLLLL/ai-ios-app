import UIKit

/// Photos attached to messages. They are stored as JPEG files next to the chat history.
enum ImageStore {
    private static let cache = NSCache<NSString, UIImage>()

    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Saves a photo and returns its file name, or nil if it could not be written.
    static func save(_ image: UIImage) -> String? {
        let prepared = image.downscaled(maxSide: 1024)
        guard let data = prepared.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        cache.setObject(prepared, forKey: name as NSString)
        return name
    }

    static func image(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func delete(_ names: [String]) {
        for name in names {
            cache.removeObject(forKey: name as NSString)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Raw pixels in the form the model expects.
    static func engineImage(named name: String) -> EngineImage? {
        guard let cgImage = image(named: name)?.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { output in
            rgba.withUnsafeBufferPointer { input in
                for pixel in 0..<(width * height) {
                    output[pixel * 3] = input[pixel * 4]
                    output[pixel * 3 + 1] = input[pixel * 4 + 1]
                    output[pixel * 3 + 2] = input[pixel * 4 + 2]
                }
            }
        }
        return EngineImage(width: width, height: height, rgb: Data(rgb))
    }
}

extension UIImage {
    /// Redraws the photo upright and no larger than `maxSide` pixels on its longer side.
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return self }
        let ratio = min(1, maxSide / longest)
        let target = CGSize(width: max(1, (size.width * ratio).rounded()), height: max(1, (size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
