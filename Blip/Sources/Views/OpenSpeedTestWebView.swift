import SwiftUI
import WebKit

/// A thin SwiftUI wrapper around `WKWebView`.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // don't persist cookies/cache on disk
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Hosts OpenSpeedTest's **public** hosted test in an embedded web view — the sanctioned
/// way to use their public service without self-hosting. The test runs inside the page
/// (their servers), so results live here rather than in Blip's native chart; for
/// integrated results (chart/history/auto-run) and full privacy, self-host a server.
struct OpenSpeedTestWebView: View {
    var body: some View {
        VStack(spacing: 0) {
            WebView(url: URL(string: "https://openspeedtest.com/")!)
                .frame(minWidth: 720, minHeight: 560)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Public test hosted by OpenSpeedTest — results stay in this window and aren't graphed in Blip. For unlimited, fully-private, graphed results, self-host a server.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
