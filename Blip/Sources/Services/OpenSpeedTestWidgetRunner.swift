import Foundation
import WebKit
import AppKit

/// Drives OpenSpeedTest's **public** hosted test in a `WKWebView` and reports the result
/// as if it were native — so the public option feeds Blip's chart like the self-hosted
/// endpoint. The web view is shown in a small window so you can watch the automated run
/// (and so WebKit never throttles its timers); it auto-starts and closes itself when the
/// result is in.
///
/// This is the sanctioned way to use OpenSpeedTest's public service (their embeddable
/// widget) — just driven and read programmatically. It scrapes the page's result fields,
/// so it's best-effort and could need updating if OpenSpeedTest changes their markup.
@MainActor
final class OpenSpeedTestWidgetRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    enum RunError: Error { case loadFailed, timedOut, noResult, cancelled }

    struct Result: Sendable { let down: Double; let up: Double?; let ping: Double? }

    /// A page that embeds the OpenSpeedTest widget (an `<iframe>` to
    /// openspeedtest.com/speedtest). The scraper is injected into all frames so it runs
    /// inside that cross-origin iframe where the result elements live.
    static let widgetURL = URL(string: "https://wemiller.com/speedtest/")!

    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Result, Error>?
    private var onLive: (@MainActor (_ isUpload: Bool, _ liveMbps: Double?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var finished = false      // continuation resumed
    private var closed = false        // window/web view torn down

    /// Runs one test. `onLive(isUpload, mbps)` reports live progress. Returns the result.
    func run(timeout: TimeInterval = 90,
             onLive: @escaping @MainActor (_ isUpload: Bool, _ liveMbps: Double?) -> Void) async throws -> Result {
        self.onLive = onLive

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(self, name: "ost")
        // forMainFrameOnly: false so the scraper also runs inside the cross-origin
        // openspeedtest.com widget iframe, where the result elements actually live.
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController = controller

        let frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self
        webView = wv

        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "OpenSpeedTest — running…"
        win.contentView = wv
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        wv.load(URLRequest(url: Self.widgetURL))

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(RunError.timedOut))
            }
        }
    }

    /// Abort an in-flight run / close a lingering window (e.g. user pressed Cancel or
    /// started a new run).
    func cancel() {
        if !finished { finish(.failure(RunError.cancelled)) } else { close() }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel(); timeoutTask = nil
        let cont = continuation; continuation = nil
        switch result {
        case .success(let v):
            cont?.resume(returning: v)
            window?.title = "OpenSpeedTest — done ✓"
            // Leave the result on screen briefly, then close.
            closeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.close()
            }
        case .failure(let e):
            cont?.resume(throwing: e)
            close()
        }
    }

    /// Tear down the web view + window. Idempotent.
    private func close() {
        guard !closed else { return }
        closed = true
        closeTask?.cancel(); closeTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        onLive = nil
        if let cont = continuation { continuation = nil; cont.resume(throwing: RunError.cancelled) }
    }

    // User closed the window manually.
    func windowWillClose(_ notification: Notification) {
        if !finished { finish(.failure(RunError.cancelled)) } else { close() }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "live":
            let status = (body["status"] as? String ?? "")
            let live = (body["live"] as? NSNumber)?.doubleValue
            onLive?(status.contains("upload"), live)
        case "done":
            guard let down = (body["down"] as? NSNumber)?.doubleValue, down > 0 else {
                finish(.failure(RunError.noResult)); return
            }
            let up = (body["up"] as? NSNumber)?.doubleValue
            let ping = (body["ping"] as? NSNumber)?.doubleValue
            finish(.success(Result(down: down, up: up, ping: ping)))
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate (load failures)

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(RunError.loadFailed))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(RunError.loadFailed))
    }

    // Injected into every frame (the widget lives in a cross-origin iframe). In frames
    // without the widget the element lookups are null, so it's a harmless no-op there.
    private static let script = """
    (function(){
      function val(id){var e=document.getElementById(id);if(!e)return null;var v=parseFloat((e.textContent||'').replace(/[^0-9.]/g,''));return isNaN(v)?null:v;}
      function txt(id){var e=document.getElementById(id);return e?(e.textContent||'').trim().toLowerCase():'';}
      function post(o){try{window.webkit.messageHandlers.ost.postMessage(o);}catch(e){}}
      // Auto-start: click the Start button as soon as it appears (once) — unless a test is
      // already running (clicking again would toggle Stop). Handles variable iframe/server
      // list load time better than a fixed delay.
      var clicked=false;
      var startIv=setInterval(function(){
        if(clicked){clearInterval(startIv);return;}
        if((val('pingResult')||0)>0||(val('downResult')||0)>0){clicked=true;clearInterval(startIv);return;}
        var b=document.getElementById('startButtonDesk')||document.getElementById('startButtonMob');
        if(b){b.click();clicked=true;clearInterval(startIv);}
      },800);
      setTimeout(function(){clearInterval(startIv);},20000);
      // Scrape live progress + the final result.
      var lastUp=null, stableSince=0, done=false;
      setInterval(function(){
        if(done) return;
        var d=val('downResult'), u=val('upRestxt'), live=val('oDoLiveSpeed'), status=txt('oDoLiveStatus');
        if(d!=null||u!=null||live!=null){ post({type:'live', status:status, live:live}); }
        // Upload is the final phase — once its value stops changing, the run is done.
        if(d!=null&&d>0&&u!=null&&u>0){
          if(u===lastUp){ if(Date.now()-stableSince>1500){ done=true; post({type:'done', down:d, up:u, ping:val('pingResult')}); } }
          else { lastUp=u; stableSince=Date.now(); }
        }
      },400);
    })();
    """
}
