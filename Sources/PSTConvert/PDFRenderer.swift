import Foundation
import WebKit
import PDFKit

/// Renders a single email (headers + body, with inline images resolved from disk)
/// into PDF data using an off-screen WKWebView. Must be driven from the main actor
/// since WebKit requires main-thread use.
@MainActor
final class PDFRenderer {

    enum RenderError: LocalizedError {
        case navigationFailed(String)
        case pdfGenerationFailed(String)
        var errorDescription: String? {
            switch self {
            case .navigationFailed(let m): return "Failed to load email content: \(m)"
            case .pdfGenerationFailed(let m): return "Failed to generate PDF: \(m)"
            }
        }
    }

    private static let pageWidth: CGFloat = 612 // US Letter width at 72 pt/inch

    /// Renders one HTML document (built by `EmailHTML.build`) to PDF data.
    /// `baseURL` should point at the directory containing any locally-referenced
    /// inline images so WKWebView is granted read access to them.
    func renderPDF(html: String, baseURL: URL?) async throws -> Data {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: Self.pageWidth, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // WKWebView needs to belong to a *visible* window to render/composite its
        // content — an invisible window reliably produces blank PDFs. Position it
        // far off the physical screen instead, so it's never actually seen, and
        // order it front without making it key so it doesn't steal focus.
        window.setIsVisible(true)
        window.orderFrontRegardless()

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.pageWidth, height: 800), configuration: config)
        window.contentView = webView

        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }

        // When inline images are involved, write the HTML to a real file inside the
        // resource directory and use loadFileURL so WKWebView is granted read access
        // to sibling image files. loadHTMLString(baseURL:) does not reliably do this.
        var htmlFileToClean: URL?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { continuation.resume() }
            delegate.onFail = { error in continuation.resume(throwing: RenderError.navigationFailed(error.localizedDescription)) }
            if let baseURL {
                let htmlFile = baseURL.appendingPathComponent(".render-\(UUID().uuidString).html")
                htmlFileToClean = htmlFile
                do {
                    try html.write(to: htmlFile, atomically: true, encoding: .utf8)
                    webView.loadFileURL(htmlFile, allowingReadAccessTo: baseURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            } else {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
        if let htmlFileToClean {
            try? FileManager.default.removeItem(at: htmlFileToClean)
        }

        await waitForImagesToLoad(webView)

        let contentHeight = (try? await evaluateDouble(webView, "document.body.scrollHeight")) ?? 800
        let height = max(200, min(contentHeight + 24, 40000))
        webView.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: height)
        window.setFrame(NSRect(x: -20000, y: -20000, width: Self.pageWidth, height: height), display: false)

        // Give WebKit a beat to relayout/paint after the resize.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = CGRect(x: 0, y: 0, width: Self.pageWidth, height: height)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: pdfConfig) { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: RenderError.pdfGenerationFailed(error.localizedDescription))
                }
            }
        }
    }

    private func waitForImagesToLoad(_ webView: WKWebView) async {
        for _ in 0..<20 {
            let complete = (try? await evaluateBool(webView, "Array.from(document.images).every(function(i){return i.complete})")) ?? true
            if complete { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func evaluateDouble(_ webView: WKWebView, _ js: String) async throws -> CGFloat {
        let result = try await webView.evaluateJavaScript(js)
        if let n = result as? NSNumber { return CGFloat(truncating: n) }
        return 800
    }

    private func evaluateBool(_ webView: WKWebView, _ js: String) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(js)
        return (result as? NSNumber)?.boolValue ?? true
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        var onFail: ((Error) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFail?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFail?(error)
        }
    }
}
