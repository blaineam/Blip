import Foundation
import WebKit
import AppKit

/// Drives OpenSpeedTest's **public** hosted test in a hidden `WKWebView` and reports the
/// result as if it were native — so the public option feeds Blip's chart like the
/// self-hosted endpoint. The web view lives in an on-screen but fully transparent,
/// click-through window so WebKit keeps the page "visible" (its timers run) while the user
/// never sees it; it auto-starts (the widget's `?run` param, plus a click fallback),
/// streams live progress to the native panel, scrapes the result, and tears down.
///
/// This is the sanctioned way to use OpenSpeedTest's public service (their embeddable
/// widget) — just driven and read programmatically. It scrapes the page's result fields,
/// so it's best-effort and could need updating if OpenSpeedTest changes their markup.
@MainActor
final class OpenSpeedTestWidgetRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    enum RunError: Error { case loadFailed, timedOut, noResult, cancelled }

    struct Result: Sendable { let down: Double; let up: Double?; let ping: Double? }

    /// A tiny in-app host page that embeds the OpenSpeedTest widget via an `<iframe>`.
    /// Loaded with an openspeedtest.com base URL so the iframe is same-origin. No local
    /// *server* is hosted — the test itself still runs against OpenSpeedTest's servers
    /// inside the iframe; this just removes any dependency on an external host page.
    static let hostHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>html,body{margin:0;height:100%;background:#0b0b0c;overflow:hidden}
    iframe{border:0;width:100%;height:100%;display:block}</style></head>
    <body><iframe src="https://openspeedtest.com/speedtest?run" allow="fullscreen" allowfullscreen></iframe></body></html>
    """
    static let baseURL = URL(string: "https://openspeedtest.com/")

    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Result, Error>?
    private var onLive: (@MainActor (_ isUpload: Bool, _ liveMbps: Double?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var finished = false      // continuation resumed
    private var closed = false        // window/web view torn down

    /// Runs one test. `onLive(isUpload, mbps)` reports live progress. Returns the result.
    func run(timeout: TimeInterval = 180,
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

        // Invisible, click-through, on-screen window. On-screen (not off-screen/occluded)
        // so WebKit keeps the page "visible" and doesn't throttle its timers; alpha 0 so
        // the user never sees it — the whole run happens in the background. Live progress
        // is surfaced through the native panel instead.
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.contentView = wv
        win.setFrameOrigin(.zero)
        win.orderFrontRegardless()
        window = win

        wv.loadHTMLString(Self.hostHTML, baseURL: Self.baseURL)

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
            close()
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
        case "state":
            // Surface live progress through the native panel (the window is invisible).
            let live = (body["live"] as? NSNumber)?.doubleValue
            let isUpload = (body["status"] as? String ?? "").lowercased().contains("upload")
            onLive?(isUpload, live)
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

    // Injected into every frame (the widget lives in an iframe). Operates on whichever
    // document actually has the widget — this frame's own document (when injected into the
    // iframe) or a same-origin child iframe reached from the main frame — and reports
    // diagnostics so the automation is observable.
    private static let script = """
    (function(){
      function num(el){if(!el)return null;var v=parseFloat((el.textContent||'').replace(/[^0-9.]/g,''));return isNaN(v)?null:v;}
      function post(o){try{window.webkit.messageHandlers.ost.postMessage(o);}catch(e){}}
      // The document that actually holds the widget: this frame's own document (when this
      // script is injected into the iframe), or a same-origin child iframe reached from the
      // main frame. Returns null until the widget elements exist.
      function widgetDoc(){
        try{ if(document.getElementById('startButtonDesk')||document.getElementById('downResult')) return document; }catch(e){}
        var ifr=document.querySelector('iframe');
        if(ifr){ try{ var d=ifr.contentDocument; if(d&&(d.getElementById('startButtonDesk')||d.getElementById('downResult'))) return d; }catch(e){} }
        return null;
      }
      function fire(el){ try{el.click();}catch(e){}
        try{['mousedown','mouseup','click'].forEach(function(t){el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}));});}catch(e){} }
      var started=false, lastUp=null, stableSince=0, done=false, ticks=0, lastClick=0;
      setInterval(function(){
        ticks++;
        var doc=widgetDoc();
        if(!doc){ if(ticks%2===0) post({type:'state', phase:'loading'}); return; }
        var btn=doc.getElementById('startButtonDesk')||doc.getElementById('startButtonMob');
        var down=num(doc.getElementById('downResult')), up=num(doc.getElementById('upRestxt')),
            live=num(doc.getElementById('oDoLiveSpeed')), ping=num(doc.getElementById('pingResult'));
        var st=doc.getElementById('oDoLiveStatus'); var status=st?(''+st.textContent).trim():'';
        if((down||0)>0||(up||0)>0||(ping||0)>0||(live||0)>0) started=true;
        // The ?run URL param should auto-start once the server list loads. As a fallback,
        // if it hasn't started after ~10s, click+dispatch on the Start button every ~2.5s
        // until it does (the started guard stops it from toggling Stop).
        if(!started && btn && ticks>20 && (Date.now()-lastClick>2500)){ lastClick=Date.now(); fire(btn); }
        if(done) return;
        post({type:'state', phase: started?'running':'starting', down:down, up:up, live:live, status:status});
        if(down!=null&&down>0&&up!=null&&up>0){
          if(up===lastUp){ if(Date.now()-stableSince>1500){ done=true; post({type:'done', down:down, up:up, ping:ping}); } }
          else { lastUp=up; stableSince=Date.now(); }
        }
      },500);
    })();
    """
}
