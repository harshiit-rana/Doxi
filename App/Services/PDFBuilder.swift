import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import UIKit

/// Builds PDFs from scanned or imported images.
enum PDFBuilder {
    /// One page per image, each page sized to the image aspect ratio (A4 width).
    static func pdf(from images: [UIImage]) -> Data {
        let pageWidth: CGFloat = 595 // A4 at 72 dpi
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: 842))
        return renderer.pdfData { ctx in
            for image in images {
                let size = image.size
                let height = size.width > 0 ? pageWidth * size.height / size.width : 842
                let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: height)
                ctx.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }

    /// Gentle clean-up for photographed pages: grayscale, more contrast, sharper text.
    static func enhance(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = 0
        controls.contrast = 1.35
        controls.brightness = 0.04
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controls.outputImage
        sharpen.sharpness = 0.5
        let context = CIContext()
        guard let output = sharpen.outputImage, let cg = context.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Returns the image rotated by 90° steps (clockwise).
    static func rotate(_ image: UIImage, clockwiseQuarterTurns turns: Int) -> UIImage {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return image }
        let size = t % 2 == 0 ? image.size : CGSize(width: image.size.height, height: image.size.width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: CGFloat(t) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
}
