import SwiftUI
import WebKit

/// A `WKWebView` that loads OpenSpeedTest's public hosted test and bridges its results
/// back to native code. OpenSpeedTest writes its numbers into DOM elements with stable
/// IDs (`downResult`, `upRestxt`, `pingResult`); an injected script watches those, waits
/// for the upload figure (the last phase) to settle, and posts the result to native via a
/// `WKScriptMessageHandler`. Optionally auto-starts the test on load.
///
/// Note: this scrapes a third-party page's DOM, so it can break if OpenSpeedTest changes
/// their markup. It's a best-effort convenience on top of the sanctioned widget embed.
struct WebView: NSViewRepresentable {
    let url: URL
    /// Called on the main actor with (downloadMbps, uploadMbps?, pingMs?) when a run completes.
    var onResult: (@MainActor (Double, Double?, Double?) -> Void)? = nil
    /// Click the test's Start button automatically once the page is ready.
    var autoStart: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "ostResult")
        controller.addUserScript(WKUserScript(
            source: Self.injection(autoStart: autoStart),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onResult: (@MainActor (Double, Double?, Double?) -> Void)?
        init(onResult: (@MainActor (Double, Double?, Double?) -> Void)?) { self.onResult = onResult }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ostResult", let body = message.body as? [String: Any] else { return }
            guard let down = (body["down"] as? NSNumber)?.doubleValue, down > 0 else { return }
            let up = (body["up"] as? NSNumber)?.doubleValue
            let ping = (body["ping"] as? NSNumber)?.doubleValue
            let handler = onResult
            Task { @MainActor in handler?(down, up, ping) }
        }
    }

    /// JS injected into the OpenSpeedTest page: scrape results + (optionally) auto-start.
    private static func injection(autoStart: Bool) -> String {
        // Single click after the server list has had time to load. One click only — a
        // second click while running would toggle the test to Stop.
        let autoStartJS = autoStart ? """
          setTimeout(function(){
            var b = document.getElementById('startButtonDesk') || document.getElementById('startButtonMob');
            if (b) { b.click(); }
          }, 3000);
        """ : ""
        return """
        (function(){
          function val(id){
            var e = document.getElementById(id);
            if(!e) return null;
            var v = parseFloat((e.textContent||'').replace(/[^0-9.]/g,''));
            return isNaN(v) ? null : v;
          }
          var lastUp = null, stableSince = 0, sentKey = '';
          setInterval(function(){
            var d = val('downResult'), u = val('upRestxt');
            // Upload is the final phase — once its value stops changing, the run is done.
            if (d!=null && d>0 && u!=null && u>0) {
              if (u === lastUp) {
                if (Date.now() - stableSince > 1500) {
                  var k = d.toFixed(2) + '/' + u.toFixed(2);
                  if (k !== sentKey) {
                    sentKey = k;
                    try { window.webkit.messageHandlers.ostResult.postMessage({down:d, up:u, ping:val('pingResult')}); } catch(e){}
                  }
                }
              } else { lastUp = u; stableSince = Date.now(); }
            } else { lastUp = null; }
          }, 500);
          \(autoStartJS)
        })();
        """
    }
}

/// Hosts OpenSpeedTest's **public** hosted test in an embedded web view — the sanctioned
/// way to use their public service without self-hosting — and feeds completed results
/// into Blip's native speed-test history/chart.
struct OpenSpeedTestWebView: View {
    /// Delivers a completed result (download Mbps, upload Mbps?, ping ms?) to the app.
    var onResult: (@MainActor (Double, Double?, Double?) -> Void)? = nil

    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            WebView(url: URL(string: "https://openspeedtest.com/")!, onResult: { down, up, ping in
                lastResult = String(format: "%.0f ↓  %@ ↑  %@ ms",
                                    down,
                                    up.map { String(format: "%.0f", $0) } ?? "—",
                                    ping.map { String(format: "%.0f", $0) } ?? "—")
                onResult?(down, up, ping)
            }, autoStart: true)
            .frame(minWidth: 720, minHeight: 560)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let r = lastResult {
                    Text("Captured: \(r) — added to Blip's chart.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                } else {
                    Text("Public test hosted by OpenSpeedTest. Completed results are added to Blip's chart. Self-host for unlimited, fully-private, auto-graphed results.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("How to self-host", destination: URL(string: "https://openspeedtest.com/selfhosted-speedtest")!)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }
}
