import SwiftUI
import WebKit

// Arayüzü (web/index.html) WKWebView içinde gösterir.
// Web tarafı window.FMBridge.send(json) ile yazar, window.onMeshRx(json) ile okur.
struct MeshWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: MeshBridge.injectedJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        ucc.add(MeshBridge.shared, name: "fm")
        config.userContentController = ucc
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.backgroundColor = .black
        MeshBridge.shared.webView = web

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
