import Foundation

/// Builds a self-contained HTML document for one email: a styled header block
/// followed by the email body (HTML if present, otherwise plain text).
enum EmailHTML {

    /// - Parameter cidMap: maps a Content-ID (without angle brackets) to the relative
    ///   filename of the extracted inline image on disk, so `cid:` references in the
    ///   HTML body can be rewritten to local file references the renderer can load.
    static func build(message: MIMEMessage, cidMap: [String: String]) -> String {
        let headerBlock = """
        <table class="pst-headers">
        \(row("From", message.from))
        \(row("To", message.to))
        \(message.cc.isEmpty ? "" : row("Cc", message.cc))
        \(row("Date", message.date))
        \(row("Subject", message.subject))
        </table>
        """

        let bodyHTML: String
        if let html = message.htmlBody, !html.isEmpty {
            bodyHTML = rewriteCIDReferences(in: extractBodyInnerHTML(html), cidMap: cidMap)
        } else if let plain = message.plainBody, !plain.isEmpty {
            bodyHTML = "<pre class=\"pst-plain\">\(escape(plain))</pre>"
        } else {
            bodyHTML = "<p class=\"pst-empty\"><em>(No message body)</em></p>"
        }

        let attachmentNames = message.attachments.compactMap { $0.filename }
        let attachmentsBlock: String
        if attachmentNames.isEmpty {
            attachmentsBlock = ""
        } else {
            let items = attachmentNames.map { "<li>\(escape($0))</li>" }.joined()
            attachmentsBlock = "<div class=\"pst-attachments\"><strong>Attachments:</strong><ul>\(items)</ul></div>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 12px; color: #111; margin: 24px; }
          table.pst-headers { width: 100%; border-collapse: collapse; margin-bottom: 16px; border-bottom: 2px solid #333; padding-bottom: 8px; }
          table.pst-headers td { padding: 2px 6px 2px 0; vertical-align: top; }
          table.pst-headers td.label { font-weight: 600; width: 70px; white-space: nowrap; }
          .pst-subject-row td { font-weight: 700; font-size: 14px; padding-top: 6px; }
          .pst-plain { white-space: pre-wrap; word-wrap: break-word; font-family: -apple-system, Menlo, monospace; font-size: 12px; }
          .pst-attachments { margin-top: 16px; border-top: 1px solid #ccc; padding-top: 8px; font-size: 11px; color: #333; }
          .pst-attachments ul { margin: 4px 0 0 0; padding-left: 18px; }
          img { max-width: 100%; }
        </style>
        </head>
        <body>
        \(headerBlock)
        <div class="pst-body">\(bodyHTML)</div>
        \(attachmentsBlock)
        </body>
        </html>
        """
    }

    private static func row(_ label: String, _ value: String) -> String {
        let cssClass = label == "Subject" ? " class=\"pst-subject-row\"" : ""
        return "<tr\(cssClass)><td class=\"label\">\(escape(label)):</td><td>\(escape(value))</td></tr>"
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    /// Outlook/readpst HTML bodies are usually full documents; pull out just the
    /// <body> contents so we can wrap them in our own document shell.
    private static func extractBodyInnerHTML(_ html: String) -> String {
        guard let bodyOpenRange = html.range(of: "<body", options: .caseInsensitive) else { return html }
        guard let tagCloseRange = html.range(of: ">", range: bodyOpenRange.upperBound..<html.endIndex) else { return html }
        let contentStart = tagCloseRange.upperBound
        guard let bodyCloseRange = html.range(of: "</body>", options: .caseInsensitive, range: contentStart..<html.endIndex) else {
            return String(html[contentStart...])
        }
        return String(html[contentStart..<bodyCloseRange.lowerBound])
    }

    private static func rewriteCIDReferences(in html: String, cidMap: [String: String]) -> String {
        guard !cidMap.isEmpty else { return html }
        var result = html
        for (cid, filename) in cidMap {
            result = result.replacingOccurrences(of: "cid:\(cid)", with: filename)
            result = result.replacingOccurrences(of: "\"cid:\(cid)\"", with: "\"\(filename)\"")
        }
        return result
    }
}
