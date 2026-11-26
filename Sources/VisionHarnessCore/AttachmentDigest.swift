import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

// MARK: - Turning what the user attached into something any model server reads
//
// The OpenAI wire format has a `file` part, and almost nothing but OpenAI's own servers accepts it: vLLM,
// llama.cpp, TabbyAPI and Ollama turn the request down, so a PDF dropped on a chat with a local model failed
// outright. A model server reads two things — text and pictures — so that is what an attachment becomes before
// it is sent:
//
//   a text file     → its text, inline, fenced and named
//   a PDF with text → its text, page by page (PDFKit)
//   a scanned PDF   → its first pages as pictures, when the model takes pictures
//   a picture       → itself, scaled down when it is larger than a model looks at anyway
//   anything else   → a line that names it and says it was not sent
//
// The result goes into the transcript in place of the original, once; nothing is converted again per request.

public enum AttachmentDigest {
    public struct Options: Sendable, Equatable {
        /// Whether the model takes pictures. Off: pictures and scanned pages are named, not sent.
        public var vision: Bool
        /// The most characters of one file's text that go inline.
        public var maxTextCharacters: Int
        /// The most pages of a scanned PDF that are sent as pictures.
        public var maxPDFPageImages: Int
        /// Pictures are scaled so their long edge is at most this many pixels.
        public var imageLongEdge: Int

        public init(vision: Bool = true, maxTextCharacters: Int = 120_000, maxPDFPageImages: Int = 4,
                    imageLongEdge: Int = 1_568) {
            self.vision = vision
            self.maxTextCharacters = maxTextCharacters
            self.maxPDFPageImages = maxPDFPageImages
            self.imageLongEdge = imageLongEdge
        }
    }

    public struct Result: Sendable, Equatable {
        /// The message text: what the user wrote, then what their files hold.
        public var text: String
        /// Only pictures are left to travel as attachments.
        public var attachments: [MessageAttachment]

        public init(text: String, attachments: [MessageAttachment]) {
            self.text = text
            self.attachments = attachments
        }
    }

    /// What a message with these attachments is sent as.
    public static func prepare(text: String, attachments: [MessageAttachment],
                               options: Options = Options()) -> Result {
        var sections: [String] = []
        var pictures: [MessageAttachment] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                if options.vision {
                    pictures.append(downscaled(attachment, longEdge: options.imageLongEdge))
                } else {
                    sections.append("[Attached picture \(attachment.name) was not sent: the selected model does not take pictures.]")
                }
            case .file:
                if isPDF(attachment) {
                    let digest = pdf(attachment, options: options)
                    sections.append(digest.text)
                    pictures.append(contentsOf: digest.pages)
                } else if let body = decodedText(attachment.data) {
                    sections.append(fenced(name: attachment.name, body: body, limit: options.maxTextCharacters))
                } else {
                    sections.append("[Attached file \(attachment.name) (\(byteCount(attachment.data.count))) is not text, a PDF or a picture, so it was not sent to the model. If it is in the project, read it with a tool instead.]")
                }
            }
        }
        let body = ([text] + sections).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Result(text: body, attachments: pictures)
    }

    // MARK: Text

    /// A file's text when it is text: UTF-8 (or UTF-16 with a byte-order mark), with no NUL bytes.
    static func decodedText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if data.count >= 2, (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)
            || (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        guard !data.prefix(8_192).contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func fenced(name: String, body: String, limit: Int) -> String {
        let (shown, cut) = clipped(body, limit: limit)
        let fence = shown.contains("```") ? "~~~~" : "```"
        var out = "Attached file \(name):\n\(fence)\n\(shown)\n\(fence)"
        if cut > 0 { out += "\n[\(name) is longer: \(cut.formatted()) more characters were left out.]" }
        return out
    }

    static func clipped(_ text: String, limit: Int) -> (shown: String, cut: Int) {
        guard text.count > limit else { return (text, 0) }
        return (String(text.prefix(limit)), text.count - limit)
    }

    static func byteCount(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(max(1, bytes / 1_024)) KB"
    }

    // MARK: PDF

    static func isPDF(_ attachment: MessageAttachment) -> Bool {
        if (attachment.name as NSString).pathExtension.lowercased() == "pdf" { return true }
        return attachment.data.prefix(5) == Data("%PDF-".utf8)
    }

    static func pdf(_ attachment: MessageAttachment, options: Options) -> (text: String, pages: [MessageAttachment]) {
        let name = attachment.name
        guard let extracted = pdfText(attachment.data) else {
            return ("[Attached PDF \(name) could not be opened (it may be damaged or password-protected), so it was not sent.]", [])
        }
        let pageCount = extracted.count
        let body = extracted.enumerated()
            .filter { !$0.element.isEmpty }
            .map { "--- page \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")
        // A text layer worth the name: more than a few characters a page on average.
        if body.count >= max(40, pageCount * 20) {
            let (shown, cut) = clipped(body, limit: options.maxTextCharacters)
            var out = "Attached PDF \(name) (\(pageCount) page\(pageCount == 1 ? "" : "s"), text extracted):\n\(shown)"
            if cut > 0 { out += "\n[\(name) is longer: \(cut.formatted()) more characters were left out. Ask for a page range to read further.]" }
            return (out, [])
        }
        // No text layer: a scan. Pictures of the first pages, when the model looks at pictures.
        guard options.vision, options.maxPDFPageImages > 0 else {
            return ("[Attached PDF \(name) (\(pageCount) page\(pageCount == 1 ? "" : "s")) is a scan with no text layer, and the selected model does not take pictures, so its contents were not sent.]", [])
        }
        let pages = pdfPageImages(attachment.data, name: name, limit: options.maxPDFPageImages,
                                  longEdge: options.imageLongEdge)
        guard !pages.isEmpty else {
            return ("[Attached PDF \(name) has no text layer and its pages could not be drawn, so it was not sent.]", [])
        }
        var out = "Attached PDF \(name) is a scan with no text layer: \(pages.count) of its \(pageCount) page\(pageCount == 1 ? "" : "s") follow\(pages.count == 1 ? "s" : "") as picture\(pages.count == 1 ? "" : "s")."
        if pageCount > pages.count { out += " Ask for other pages by number." }
        return (out, pages)
    }

    /// The text of each page; nil when the document can't be opened.
    static func pdfText(_ data: Data) -> [String]? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        return (0..<document.pageCount).map { index in
            (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #else
        return nil
        #endif
    }

    /// The first `limit` pages drawn as PNGs.
    static func pdfPageImages(_ data: Data, name: String, limit: Int, longEdge: Int) -> [MessageAttachment] {
        #if canImport(ImageIO)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return [] }
        var out: [MessageAttachment] = []
        let base = (name as NSString).deletingPathExtension
        for number in 1...min(limit, document.numberOfPages) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 1, box.height > 1 else { continue }
            let scale = CGFloat(longEdge) / max(box.width, box.height)
            let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                         rotate: 0, preserveAspectRatio: true))
            // getDrawingTransform never scales up; a small page is scaled to the target here.
            let fitted = CGFloat(width) / box.width
            if fitted > 1 {
                context.translateBy(x: box.midX, y: box.midY)
                context.scaleBy(x: fitted, y: fitted)
                context.translateBy(x: -box.midX, y: -box.midY)
            }
            context.drawPDFPage(page)
            guard let image = context.makeImage(), let png = encode(image, type: "public.png") else { continue }
            out.append(MessageAttachment(kind: .image, name: "\(base)-page-\(number).png", data: png))
        }
        return out
        #else
        return []
        #endif
    }

    // MARK: Pictures

    /// The picture, scaled so its long edge is at most `longEdge`. Smaller pictures, and ones that can't be read,
    /// come back as they were.
    public static func downscaled(_ attachment: MessageAttachment, longEdge: Int) -> MessageAttachment {
        #if canImport(ImageIO)
        guard let size = ImageSize.dimensions(of: attachment.data), max(size.width, size.height) > longEdge,
              let source = CGImageSourceCreateWithData(attachment.data as CFData, nil) else { return attachment }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return attachment }
        // Screenshots and diagrams stay PNG (text edges matter); photographs go to JPEG.
        let isPhoto = ["jpg", "jpeg", "heic"].contains((attachment.name as NSString).pathExtension.lowercased())
        guard let data = encode(image, type: isPhoto ? "public.jpeg" : "public.png", quality: 0.85) else { return attachment }
        var name = attachment.name
        if isPhoto, (name as NSString).pathExtension.lowercased() == "heic" {
            name = (name as NSString).deletingPathExtension + ".jpg"
        }
        return MessageAttachment(kind: .image, name: name, data: data)
        #else
        return attachment
        #endif
    }

    #if canImport(ImageIO)
    static func encode(_ image: CGImage, type: String, quality: Double = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    #endif
}
