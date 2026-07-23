import Foundation

/// A single MIME body part, possibly with children if it is a multipart container.
struct MIMEPart {
    var headers: [String: String] = [:]   // lowercased header name -> raw value (unfolded)
    var contentType: String = "text/plain"
    var charset: String?
    var contentID: String?
    var filename: String?
    var isAttachment: Bool = false
    var data: Data = Data()               // decoded bytes, populated for leaf parts
    var children: [MIMEPart] = []

    var isMultipart: Bool { contentType.hasPrefix("multipart/") }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Depth-first search for the first part matching a predicate.
    func firstPart(where predicate: (MIMEPart) -> Bool) -> MIMEPart? {
        if predicate(self) { return self }
        for child in children {
            if let found = child.firstPart(where: predicate) { return found }
        }
        return nil
    }

    /// All leaf parts flagged as attachments, anywhere in the tree.
    func allAttachments() -> [MIMEPart] {
        var result: [MIMEPart] = []
        if isAttachment && !isMultipart { result.append(self) }
        for child in children { result.append(contentsOf: child.allAttachments()) }
        return result
    }

    var decodedText: String? {
        let cs = MIMEDecoding.stringEncoding(forCharset: charset)
        return String(data: data, encoding: cs) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

struct MIMEMessage {
    var headers: [String: String]
    var root: MIMEPart

    var subject: String { MIMEDecoding.decodeHeaderValue(headers["subject"]) ?? "(No Subject)" }
    var from: String { MIMEDecoding.decodeHeaderValue(headers["from"]) ?? "" }
    var to: String { MIMEDecoding.decodeHeaderValue(headers["to"]) ?? "" }
    var cc: String { MIMEDecoding.decodeHeaderValue(headers["cc"]) ?? "" }
    var date: String { headers["date"] ?? "" }

    var htmlBody: String? {
        root.firstPart(where: { $0.contentType == "text/html" })?.decodedText
    }

    var plainBody: String? {
        root.firstPart(where: { $0.contentType == "text/plain" })?.decodedText
    }

    var attachments: [MIMEPart] { root.allAttachments() }

    static func parse(data: Data) -> MIMEMessage {
        let (headers, bodyRange) = MIMEDecoding.parseHeaderBlock(data)
        let body = data.subdata(in: bodyRange)
        let root = MIMEDecoding.parsePart(headers: headers, body: body)
        return MIMEMessage(headers: headers, root: root)
    }
}

enum MIMEDecoding {

    /// Splits a raw RFC822 message/part into (headers, bodyRange), handling header folding.
    static func parseHeaderBlock(_ data: Data) -> (headers: [String: String], bodyRange: Range<Data.Index>) {
        let crlfcrlf: [UInt8] = [13, 10, 13, 10]
        let lflf: [UInt8] = [10, 10]

        var headerEnd = data.endIndex
        var bodyStart = data.endIndex
        if let r = data.firstRange(of: Data(crlfcrlf)) {
            headerEnd = r.lowerBound
            bodyStart = r.upperBound
        } else if let r = data.firstRange(of: Data(lflf)) {
            headerEnd = r.lowerBound
            bodyStart = r.upperBound
        }

        let headerData = data.subdata(in: data.startIndex..<headerEnd)
        let headerText = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) ?? ""

        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""
        func commit() {
            if let name = currentName {
                let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = headers[name] {
                    headers[name] = existing + ", " + trimmed
                } else {
                    headers[name] = trimmed
                }
            }
        }
        for rawLine in headerText.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                commit()
                currentName = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()

        return (headers, bodyStart..<data.endIndex)
    }

    /// Parses a content-type header into (type/subtype, [param: value]).
    static func parseContentType(_ raw: String?) -> (type: String, params: [String: String]) {
        guard let raw = raw, !raw.isEmpty else { return ("text/plain", [:]) }
        let segments = splitParams(raw)
        let type = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            let parts = seg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            params[key] = value
        }
        return (type.isEmpty ? "text/plain" : type, params)
    }

    /// Splits a "type; a=b; c=d" style header respecting quoted strings.
    private static func splitParams(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func parsePart(headers: [String: String], body: Data) -> MIMEPart {
        var part = MIMEPart()
        part.headers = headers

        let (ctype, ctParams) = parseContentType(headers["content-type"])
        part.contentType = ctype
        part.charset = ctParams["charset"]

        let (_, cdParams) = parseContentType(headers["content-disposition"])
        let disposition = headers["content-disposition"]?.lowercased() ?? ""

        let name = decodeHeaderValue(cdParams["filename"] ?? ctParams["name"])
        part.filename = name
        part.contentID = headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

        if ctype.hasPrefix("multipart/"), let boundary = ctParams["boundary"] {
            part.children = splitMultipart(body: body, boundary: boundary)
            part.isAttachment = false
        } else {
            let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
            part.data = decodeBody(body, encoding: encoding)
            let isInlineText = (ctype == "text/plain" || ctype == "text/html")
            if disposition.hasPrefix("attachment") {
                part.isAttachment = true
            } else if name != nil && !isInlineText {
                part.isAttachment = true
            } else if disposition.hasPrefix("inline") && name != nil && !isInlineText {
                part.isAttachment = true
            } else {
                part.isAttachment = false
            }
        }
        return part
    }

    private static func splitMultipart(body: Data, boundary: String) -> [MIMEPart] {
        guard let delim = "--\(boundary)".data(using: .utf8) else { return [] }
        var parts: [MIMEPart] = []
        var searchStart = body.startIndex
        var ranges: [Range<Data.Index>] = []
        while let r = body.range(of: delim, in: searchStart..<body.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        guard ranges.count >= 2 else { return [] }
        for i in 0..<(ranges.count - 1) {
            var segStart = ranges[i].upperBound
            let segEnd = ranges[i + 1].lowerBound
            guard segStart < segEnd else { continue }
            // skip leading CRLF right after boundary marker
            if segStart < body.endIndex, body[segStart] == 13 { segStart = body.index(after: segStart) }
            if segStart < body.endIndex, body[segStart] == 10 { segStart = body.index(after: segStart) }
            guard segStart < segEnd else { continue }
            var segment = body.subdata(in: segStart..<segEnd)
            // trim trailing CRLF before the boundary
            while segment.last == 10 || segment.last == 13 { segment.removeLast() }
            let (subHeaders, subBodyRange) = parseHeaderBlock(segment)
            let subBody = segment.subdata(in: subBodyRange)
            parts.append(parsePart(headers: subHeaders, body: subBody))
        }
        return parts
    }

    static func decodeBody(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let text = String(data: data, encoding: .ascii) ?? ""
            let cleaned = text.filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 2 < bytes.count {
                    let c1 = bytes[i + 1], c2 = bytes[i + 2]
                    if c1 == 13 && c2 == 10 { // soft line break =\r\n
                        i += 3
                        continue
                    }
                    if c1 == 10 { // soft line break =\n
                        i += 2
                        continue
                    }
                    if let hi = hexVal(c1), let lo = hexVal(c2) {
                        out.append(UInt8(hi * 16 + lo))
                        i += 3
                        continue
                    }
                }
                out.append(b)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return Data(out)
    }

    private static func hexVal(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41) + 10
        case 0x61...0x66: return Int(b - 0x61) + 10
        default: return nil
        }
    }

    static func stringEncoding(forCharset charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased() else { return .utf8 }
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "utf-16", "utf16": return .utf16
        default: return .utf8
        }
    }

    /// Decodes RFC 2047 encoded-words (=?charset?B?...?= / =?charset?Q?...?=) in header values.
    static func decodeHeaderValue(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        guard raw.contains("=?") else { return raw }
        var result = ""
        let remainder = Substring(raw)
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }

        var lastEnd = remainder.startIndex
        let nsrange = NSRange(remainder.startIndex..<remainder.endIndex, in: remainder)
        let matches = regex.matches(in: String(remainder), range: nsrange)
        guard !matches.isEmpty else { return raw }

        for match in matches {
            guard let range = Range(match.range, in: remainder) else { continue }
            result += remainder[lastEnd..<range.lowerBound]
            guard let charsetRange = Range(match.range(at: 1), in: remainder),
                  let encRange = Range(match.range(at: 2), in: remainder),
                  let textRange = Range(match.range(at: 3), in: remainder) else { continue }
            let charset = String(remainder[charsetRange])
            let enc = String(remainder[encRange]).lowercased()
            let text = String(remainder[textRange])
            let stringEnc = stringEncoding(forCharset: charset)
            if enc == "b" {
                if let decoded = Data(base64Encoded: text), let s = String(data: decoded, encoding: stringEnc) {
                    result += s
                } else {
                    result += text
                }
            } else { // "q" - quoted printable, with _ meaning space
                let underscored = text.replacingOccurrences(of: "_", with: " ")
                if let data = underscored.data(using: .ascii) {
                    let decoded = decodeQuotedPrintable(data)
                    result += String(data: decoded, encoding: stringEnc) ?? underscored
                } else {
                    result += underscored
                }
            }
            lastEnd = range.upperBound
        }
        result += remainder[lastEnd...]
        return result
    }
}
