import AppKit
import WebKit

/// Owns one WKWebView per service. They live as long as the app runs,
/// so your chat is still there when you reopen the window.
@MainActor
final class WebManager: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate, NSWindowDelegate {
    static let shared = WebManager()

    private var views: [Service: WKWebView] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Prompts from the quick bar waiting for their new chat page to load.
    private var pendingPrompts: [Service: PendingPrompt] = [:]

    private struct PendingPrompt {
        let text: String
        let files: [URL]
        /// True when the prompt was put in the URL (?q=), so the page may send it on its own.
        var viaURL = false
    }

    /// Services where the quick bar opened a fresh chat in the background, so it is
    /// ready the moment you press Return. Undone if you close the bar without sending.
    private var prewarmed: Set<Service> = []
    private var popups: [NSWindow] = []

    /// Regular Safari user agent, so the sites treat us like a normal browser.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Domains that open inside the window. Other links open in the default browser.
    private static let internalHosts = [
        "chatgpt.com", "openai.com", "claude.ai", "claude.com", "anthropic.com",
        "google.com", "apple.com", "microsoftonline.com", "live.com", "microsoft.com",
    ]

    private static let focusScript = """
    (() => {
      const el = document.querySelector('#prompt-textarea, div.ProseMirror[contenteditable="true"], div[contenteditable="true"], textarea');
      if (el) { el.focus(); }
      return true;
    })();
    """


    /// Checks every half second whether the page is writing an answer (a stop button exists)
    /// and tells the app when that changes.
    private static let watcherScript = #"""
    (() => {
      if (window.__miniChatWatcher) return;
      window.__miniChatWatcher = true;
      let last = null;
      const isBusy = () => !!document.querySelector(
        '[data-testid="stop-button"], [data-is-streaming="true"], button[aria-label*="stop" i]'
      );
      setInterval(() => {
        const busy = isBusy();
        if (busy !== last) {
          last = busy;
          try { window.webkit.messageHandlers.minichat.postMessage({ busy }); } catch (e) {}
        }
      }, 500);
    })();
    """#

    func webView(for service: Service) -> WKWebView {
        if let existing = views[service] { return existing }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // keeps you signed in across restarts
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.watcherScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.add(self, name: "minichat")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: service.homeURL))
        views[service] = webView

        // Remember visited chats (URL and title change without a full page load).
        observations.append(webView.observe(\.url, options: [.new]) { _, _ in
            Task { @MainActor in WebManager.shared.noteVisit(service) }
        })
        observations.append(webView.observe(\.title, options: [.new]) { _, _ in
            Task { @MainActor in WebManager.shared.noteVisit(service) }
        })
        return webView
    }

    private func noteVisit(_ service: Service) {
        let webView = webView(for: service)
        guard let url = webView.url else { return }
        AppState.shared.recordVisit(service: service, url: url, title: webView.title)
    }

    func load(_ address: String, in service: Service) {
        guard let url = URL(string: address) else { return }
        let webView = webView(for: service)
        if webView.url?.absoluteString.hasPrefix(address) == true { return }
        webView.load(URLRequest(url: url))
    }

    func newChat(_ service: Service) {
        webView(for: service).load(URLRequest(url: service.homeURL))
    }

    /// Starts a new chat and sends the prompt. The prompt goes in the URL (?q=),
    /// which both sites have supported. If the page doesn't send it on its own,
    /// sendPendingPrompt types it into the input and presses send.
    /// With attachments, the URL trick is skipped (it would send before the files are
    /// added): the files are pasted into the input first, then the text is typed and sent.
    func startChat(_ prompt: String, files: [URL] = [], in service: Service) {
        var url = service.homeURL
        if files.isEmpty, !prompt.isEmpty {
            var components = URLComponents(url: service.homeURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "q", value: prompt)]
            url = components?.url ?? url
        }
        pendingPrompts[service] = PendingPrompt(text: prompt, files: files, viaURL: files.isEmpty && !prompt.isEmpty)
        webView(for: service).load(URLRequest(url: url))
    }

    // MARK: Quick bar speed-up

    private func isFreshChat(_ webView: WKWebView, _ service: Service) -> Bool {
        guard let url = webView.url, url.query == nil else { return false }
        switch service {
        case .chatgpt: return url.host?.hasSuffix("chatgpt.com") == true && (url.path.isEmpty || url.path == "/")
        case .claude: return url.host?.hasSuffix("claude.ai") == true && url.path == "/new"
        }
    }

    /// Called when the quick bar opens: loads an empty chat in both services while you type.
    func prewarmNewChat() {
        for service in Service.allCases {
            let webView = webView(for: service)
            guard !isFreshChat(webView, service) else { continue }
            prewarmed.insert(service)
            webView.load(URLRequest(url: service.homeURL))
        }
    }

    /// Takes the other services back to the chat they showed before.
    private func restore(except kept: Service?) {
        for service in prewarmed where service != kept {
            let webView = webView(for: service)
            if webView.canGoBack { webView.goBack() }
        }
        prewarmed.removeAll()
    }

    /// The quick bar was closed or ⌘Return was used: go back to the previous chats.
    func undoPrewarm() {
        restore(except: nil)
    }

    /// Return with nothing typed: keep the fresh chat in this service.
    func keepFreshChat(in service: Service) {
        restore(except: service)
        if !isFreshChat(webView(for: service), service) { newChat(service) }
    }

    /// Return with a question: sends it in the chat that is already open and empty,
    /// instead of loading a new page first.
    func sendFromBar(_ prompt: String, files: [URL], in service: Service) {
        restore(except: service)
        let webView = webView(for: service)
        guard isFreshChat(webView, service) else {
            startChat(prompt, files: files, in: service)
            return
        }
        let pending = PendingPrompt(text: prompt, files: files)
        if webView.isLoading {
            pendingPrompts[service] = pending // sent from didFinish
        } else if files.isEmpty {
            sendPendingPrompt(prompt, in: service, waitFirst: false)
        } else {
            sendWithAttachments(pending, in: service)
        }
    }

    private static let sendAfterUploadScript = #"""
    const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
    const input = document.querySelector('#prompt-textarea, div.ProseMirror[contenteditable="true"], div[contenteditable="true"], textarea');
    if (input && text) {
      input.focus();
      document.execCommand('insertText', false, text);
    }
    const findSend = () => document.querySelector('[data-testid="send-button"], button[aria-label*="send" i]');
    const ready = button => button && !button.disabled && button.getAttribute('aria-disabled') !== 'true';
    // Wait (up to about 30 s) until the uploads are done and the send button is enabled.
    for (let i = 0; i < 100; i++) {
      if (ready(findSend())) {
        await wait(250);
        const button = findSend();
        if (ready(button)) { button.click(); return 'clicked'; }
      }
      await wait(300);
    }
    return 'timeout';
    """#

    /// Pastes the files into the chat input through the clipboard (the same way as ⌘V),
    /// then types the text and sends once the upload is done. The clipboard is restored.
    private func sendWithAttachments(_ pending: PendingPrompt, in service: Service) {
        focusInput(service)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let webView = self.webView(for: service)
            let snapshot = AttachmentStore.snapshotPasteboard()
            AttachmentStore.writeToPasteboard(pending.files)
            webView.window?.makeFirstResponder(webView)
            NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AttachmentStore.restorePasteboard(snapshot)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.callAsyncJavaScript(
                    Self.sendAfterUploadScript, arguments: ["text": pending.text], in: nil, in: .page
                ) { result in
                    if case .failure(let error) = result {
                        NSLog("Mini Chat: could not send attachment: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private static let sendPromptScript = #"""
    const isBusy = () => !!document.querySelector('[data-testid="stop-button"], [data-is-streaming="true"], button[aria-label*="stop" i]');
    const hasUserMessage = () => !!document.querySelector('[data-message-author-role="user"], [data-testid="user-message"]');
    const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

    // If the prompt was in the URL (?q=), give the page a moment to send it on its own.
    for (let i = 0; i < (waitFirst ? 10 : 0); i++) {
      if (isBusy() || hasUserMessage()) return 'sent';
      await wait(300);
    }

    // The page may still be starting up: wait (up to 10 s) for the input to exist.
    const selector = '#prompt-textarea, div.ProseMirror[contenteditable="true"], div[contenteditable="true"], textarea';
    let input = null;
    for (let i = 0; i < 40 && !(input = document.querySelector(selector)); i++) await wait(250);
    if (!input) return 'no-input';
    input.focus();
    const current = ((input.value !== undefined ? input.value : input.innerText) || '').trim();
    if (!current) {
      document.execCommand('insertText', false, text);
    }
    // Click send as soon as the page enables the button (usually within a few ms).
    for (let i = 0; i < 40; i++) {
      const send = document.querySelector('[data-testid="send-button"], button[aria-label*="send" i]');
      if (send && !send.disabled && send.getAttribute('aria-disabled') !== 'true') { send.click(); return 'clicked'; }
      await wait(50);
    }
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    return 'enter';
    """#

    private func sendPendingPrompt(_ prompt: String, in service: Service, waitFirst: Bool = true) {
        webView(for: service).callAsyncJavaScript(
            Self.sendPromptScript, arguments: ["text": prompt, "waitFirst": waitFirst], in: nil, in: .page
        ) { result in
            if case .failure(let error) = result {
                NSLog("Mini Chat: could not send prompt: \(error.localizedDescription)")
            }
        }
    }

    func reload(_ service: Service) {
        webView(for: service).reload()
    }

    func openInBrowser(_ service: Service) {
        let url = webView(for: service).url ?? service.homeURL
        NSWorkspace.shared.open(url)
    }

    func focusInput(_ service: Service) {
        let webView = webView(for: service)
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript(Self.focusScript, completionHandler: nil)
    }

    /// Takes a tiny snapshot of the top strip of the page and uses
    /// its color, so the top bar matches exactly what you see.
    func refreshTheme(_ service: Service) {
        let webView = webView(for: service)
        // Skip while loading: a blank page would be read as white.
        guard webView.window != nil, !webView.isLoading,
              webView.bounds.width > 20, webView.bounds.height > 20 else { return }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: webView.bounds.width, height: 6)
        configuration.afterScreenUpdates = true

        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image, let rgb = Self.dominantColor(in: image) else { return }
            Task { @MainActor in
                AppState.shared.setTheme(red: rgb.0, green: rgb.1, blue: rgb.2, for: service)
            }
        }
    }

    /// Finds the most common color in the image (in sRGB).
    nonisolated static func dominantColor(in image: NSImage) -> (Double, Double, Double)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var counts: [UInt32: Int] = [:]
        let step = max(1, width / 60)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: step) {
                let i = (y * width + x) * 4
                guard pixels[i + 3] > 200 else { continue }
                let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                counts[key, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (
            Double((best >> 16) & 0xFF) / 255,
            Double((best >> 8) & 0xFF) / 255,
            Double(best & 0xFF) / 255
        )
    }

    private func service(for webView: WKWebView) -> Service? {
        views.first { $0.value === webView }?.key
    }

    private static func isInternal(_ host: String) -> Bool {
        internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Messages from the page

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "minichat",
              let body = message.body as? [String: Any],
              let busy = body["busy"] as? Bool,
              let webView = message.webView,
              let service = service(for: webView) else { return }
        AppState.shared.setBusy(busy, for: service)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let service = service(for: webView) else { return }
        if let pending = pendingPrompts.removeValue(forKey: service) {
            let delay = pending.viaURL ? 0.8 : (pending.files.isEmpty ? 0.3 : 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if pending.files.isEmpty {
                    self.sendPendingPrompt(pending.text, in: service, waitFirst: pending.viaURL)
                } else {
                    self.sendWithAttachments(pending, in: service)
                }
            }
        }
        refreshTheme(service)
        // Some pages set their color shortly after loading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.refreshTheme(service)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Links with a download attribute (typically files the assistant created).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let host = url.host,
           !Self.isInternal(host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Files meant to be downloaded, or that can't be displayed: save to Downloads.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        // Images, PDFs and similar: open in the browser instead of taking over the window.
        if navigationResponse.isForMainFrame,
           let mime = navigationResponse.response.mimeType?.lowercased(),
           !mime.hasPrefix("text/html"),
           !mime.hasPrefix("application/xhtml"),
           let url = navigationResponse.response.url,
           url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: Crash recovery

    /// If the page's web process crashes, the view goes blank. Reload it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil {
            webView.reload()
        } else if let service = service(for: webView) {
            webView.load(URLRequest(url: service.homeURL))
        }
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniqueURL(in: folder, name: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Makes the Downloads stack in the Dock bounce, like Safari does.
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path
        )
        Notifier.postDownload(url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    }

    /// "file.pdf" becomes "file 2.pdf" if it already exists.
    private static func uniqueURL(in folder: URL, name: String) -> URL {
        let safeName = name.isEmpty ? L("Nedlasting") : name.replacingOccurrences(of: "/", with: "-")
        var candidate = folder.appendingPathComponent(safeName)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(next)
            number += 1
        }
        return candidate
    }

    // MARK: New windows (Google/Apple sign-in, target=_blank links)

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Regular links that want a new tab: send them to the browser.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            return nil
        }

        // Script-opened windows (typically sign-in): show them in a small separate window.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 680), configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self

        let window = NSWindow(
            contentRect: popup.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Logg inn"
        window.contentView = popup
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        popups.append(window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = webView.window, popups.contains(window) else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        popups.removeAll { $0 == window }
    }

    // MARK: File uploads and JavaScript dialogs

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Avbryt"))
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
