import Foundation

enum AttachmentKind {
    case image
    case pdf
    case other
}

/// Builds a small cover page announcing an attachment inside the combined PDF binder.
enum AttachmentInfoHTML {
    static func build(filename: String, sizeString: String, kind: AttachmentKind) -> String {
        let glyph: String
        let note: String
        switch kind {
        case .image:
            glyph = "🖼️"
            note = "The image follows on the next page."
        case .pdf:
            glyph = "📄"
            note = "The document's pages follow immediately after this one."
        case .other:
            glyph = "📎"
            note = "This file type can't be shown as pages here — a copy has been saved in the \u{201C}Attachments\u{201D} folder next to this PDF."
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 24px; color: #111; }
          .glyph { font-size: 48px; margin-bottom: 12px; }
          .filename { font-size: 16px; font-weight: 700; word-break: break-word; }
          .meta { font-size: 12px; color: #555; margin-top: 4px; }
          .note { font-size: 12px; color: #333; margin-top: 20px; border-top: 1px solid #ccc; padding-top: 10px; }
        </style>
        </head>
        <body>
          <div class="glyph">\(glyph)</div>
          <div class="filename">Attachment: \(escape(filename))</div>
          <div class="meta">\(escape(sizeString))</div>
          <div class="note">\(note)</div>
        </body>
        </html>
        """
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    static func classify(filename: String, data: Data) -> AttachmentKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp"]
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if ext.isEmpty {
            // Fall back to magic-byte sniffing when there's no useful extension.
            if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf } // %PDF
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image } // PNG
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image } // JPEG
            if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return .image }
        }
        return .other
    }
}
