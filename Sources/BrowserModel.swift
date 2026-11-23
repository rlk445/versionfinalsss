import SwiftUI
import WebKit

enum BrowserSub {
    case page, menu, bookmarks, history
}

func jsString(_ s: String) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
       let j = String(data: d, encoding: .utf8) {
        return j + "[0]"
    }
    return "\"\""
}

/// Uma guia do navegador (um WKWebView).
final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let id = UUID()
    let web: WKWebView
    weak var owner: BrowserModel?
    private var observers: [NSKeyValueObservation] = []

    init(owner: BrowserModel) {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        web = w
        self.owner = owner
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        observers.append(web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.changed() })
        observers.append(web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.changed() })
        observers.append(web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.changed() })
        observers.append(web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.changed() })
        observers.append(web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.changed() })
        observers.append(web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.changed() })
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.owner?.tabChanged(self)
        }
    }

    var isHome: Bool {
        guard let u = web.url else { return true }
        return u.isFileURL
    }

    var displayTitle: String {
        if isHome { return "Nova guia" }
        if let t = web.title, !t.isEmpty { return t }
        return web.url?.host ?? "Carregando…"
    }

    var urlString: String {
        if isHome { return "" }
        return web.url?.absoluteString ?? ""
    }

    func loadHome() {
        if let u = Bundle.main.url(forResource: "newtab", withExtension: "html", subdirectory: "browser") {
            web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
        } else {
            web.loadHTMLString("<html><body style='background:#1c1e21;color:#eee;font-family:sans-serif'><h2>Nova guia</h2></body></html>", baseURL: nil)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, !u.isFileURL {
            owner?.addHistory(title: webView.title ?? "", url: u.absoluteString)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        owner?.app?.menu.showToast(message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = MediaModel.downloadsDir
        var name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        name = name.replacingOccurrences(of: "/", with: "_")
        var dest = dir.appendingPathComponent(name)
        var n = 1
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            dest = dir.appendingPathComponent(newName)
            n += 1
        }
        completionHandler(dest)
        owner?.app?.menu.showToast("Baixando " + dest.lastPathComponent)
    }

    func downloadDidFinish(_ download: WKDownload) {
        owner?.app?.notifs.post(title: "Download concluído", body: "Salvo em Arquivos > Downloads", icon: "arrow.down.circle.fill")
        owner?.app?.media.refresh()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        owner?.app?.notifs.post(title: "Falha no download", body: error.localizedDescription, icon: "exclamationmark.triangle.fill")
    }
}

/// Navegador (port do Browser.java): guias, histórico, favoritos, zoom, modo teatro, digitação e cliques por pinça.
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var current = 0
    @Published var sub: BrowserSub = .none
    @Published var theater = false
    @Published var zoomIdx = 1
    @Published var tick = 0
    weak var app: AppModel?

    static let zooms: [CGFloat] = [0.8, 1.0, 1.25, 1.5]
    private let bookmarksKey = "browser_bookmarks"
    private let historyKey = "browser_history"

    var currentTab: BrowserTab? {
        if current >= 0 && current < tabs.count { return tabs[current] }
        return nil
    }

    func tabChanged(_ t: BrowserTab) {
        tick += 1
    }

    // MARK: guias

    func ensureTab() {
        if tabs.isEmpty { newTab(nil) }
    }

    func newTab(_ url: String?) {
        let t = BrowserTab(owner: self)
        t.web.pageZoom = BrowserModel.zooms[max(0, min(zoomIdx, BrowserModel.zooms.count - 1))]
        tabs.append(t)
        current = tabs.count - 1
        sub = .page
        if let u = url, !u.isEmpty {
            go(u)
        } else {
            t.loadHome()
        }
    }

    func select(_ i: Int) {
        if i >= 0 && i < tabs.count {
            current = i
            sub = .page
        }
    }

    func closeTab(_ i: Int) {
        guard i >= 0 && i < tabs.count else { return }
        tabs[i].web.stopLoading()
        tabs.remove(at: i)
        if tabs.isEmpty {
            app?.menu.window = nil
            app?.keyboard.close()
            current = 0
            return
        }
        if i < current {
            current -= 1
        } else if current >= tabs.count {
            current = tabs.count - 1
        }
    }

    func closeAllTabs() {
        for t in tabs { t.web.stopLoading() }
        tabs.removeAll()
        current = 0
        app?.menu.window = nil
        app?.keyboard.close()
        app?.menu.showToast("Navegador fechado")
    }

    // MARK: navegação

    func go(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        var target = s
        if !s.contains("://") {
            if s.contains(" ") || !s.contains(".") || s.hasSuffix(".") {
                let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
                target = "https://www.google.com/search?q=" + q
            } else {
                target = "https://" + s
            }
        }
        guard let url = URL(string: target) else { return }
        if currentTab == nil {
            let t = BrowserTab(owner: self)
            tabs.append(t)
            current = tabs.count - 1
        }
        sub = .page
        currentTab?.web.load(URLRequest(url: url))
    }

    func back() { currentTab?.web.goBack() }
    func forward() { currentTab?.web.goForward() }

    func reloadOrStop() {
        guard let t = currentTab else { return }
        if t.web.isLoading { t.web.stopLoading() } else if t.isHome { t.loadHome() } else { t.web.reload() }
    }

    func home() { currentTab?.loadHome(); sub = .page }

    func setZoom(_ i: Int) {
        zoomIdx = max(0, min(i, BrowserModel.zooms.count - 1))
        for t in tabs { t.web.pageZoom = BrowserModel.zooms[zoomIdx] }
    }

    func clearData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date.distantPast) { }
        UserDefaults.standard.removeObject(forKey: historyKey)
        tick += 1
        app?.menu.showToast("Dados de navegação apagados")
    }

    // MARK: favoritos e histórico (cada item: [título, url])

    var bookmarks: [[String]] { return UserDefaults.standard.array(forKey: bookmarksKey) as? [[String]] ?? [] }
    var history: [[String]] { return UserDefaults.standard.array(forKey: historyKey) as? [[String]] ?? [] }

    var isBookmarked: Bool {
        guard let t = currentTab, !t.isHome else { return false }
        return bookmarks.contains(where: { $0.count > 1 && $0[1] == t.urlString })
    }

    func toggleBookmark() {
        guard let t = currentTab, !t.isHome else { return }
        var list = bookmarks
        if let i = list.firstIndex(where: { $0.count > 1 && $0[1] == t.urlString }) {
            list.remove(at: i)
            app?.menu.showToast("Favorito removido")
        } else {
            list.insert([t.displayTitle, t.urlString], at: 0)
            app?.menu.showToast("Favorito adicionado")
        }
        UserDefaults.standard.set(list, forKey: bookmarksKey)
        tick += 1
    }

    func removeBookmark(_ i: Int) {
        var list = bookmarks
        if i >= 0 && i < list.count {
            list.remove(at: i)
            UserDefaults.standard.set(list, forKey: bookmarksKey)
            tick += 1
        }
    }

    func addHistory(title: String, url: String) {
        var list = history
        if let first = list.first, first.count > 1, first[1] == url { return }
        list.insert([title.isEmpty ? url : title, url], at: 0)
        if list.count > 100 { list = Array(list.prefix(100)) }
        UserDefaults.standard.set(list, forKey: historyKey)
    }

    // MARK: ações vindas de botões ("b:web:<ação>")

    func action(_ a: String) {
        guard let app = app else { return }
        switch a {
        case "back": back()
        case "fwd": forward()
        case "reload": reloadOrStop()
        case "home": home()
        case "url":
            app.keyboard.open(.url, initial: currentTab?.urlString ?? "")
        case "star": toggleBookmark()
        case "menu": toggleSub(.menu)
        case "bookmarks": toggleSub(.bookmarks)
        case "history": toggleSub(.history)
        case "newtab": newTab(nil)
        case "theater":
            theater.toggle()
        case "clear": clearData()
        case "closeall": closeAllTabs()
        default:
            if a.hasPrefix("tab:") {
                select(Int(a.dropFirst(4)) ?? 0)
            } else if a.hasPrefix("close:") {
                closeTab(Int(a.dropFirst(6)) ?? 0)
            } else if a.hasPrefix("zoom:") {
                setZoom(Int(a.dropFirst(5)) ?? 1)
            } else if a.hasPrefix("open:") {
                let i = Int(a.dropFirst(5)) ?? 0
                let list = (sub == .bookmarks) ? bookmarks : history
                if i >= 0 && i < list.count && list[i].count > 1 { go(list[i][1]) }
            } else if a.hasPrefix("rmbm:") {
                removeBookmark(Int(a.dropFirst(5)) ?? 0)
            }
        }
    }

    private func toggleSub(_ s: BrowserSub) {
        sub = (sub == s) ? .page : s
        app?.menu.scroll = 0
    }

    // MARK: entrada por pinça e teclado virtual

    func scrollBy(dx: CGFloat, dy: CGFloat) {
        guard let sv = currentTab?.web.scrollView else { return }
        var o = sv.contentOffset
        let minY = -sv.adjustedContentInset.top
        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let minX = -sv.adjustedContentInset.left
        let maxX = max(minX, sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right)
        o.y = min(max(o.y + dy, minY), maxY)
        o.x = min(max(o.x + dx, minX), maxX)
        sv.setContentOffset(o, animated: false)
    }

    /// Pinça sem arrastar sobre a página = clique. `p` está em coordenadas da tela.
    func tap(atGlobal p: CGPoint) {
        guard let t = currentTab else { return }
        let local = t.web.convert(p, from: nil)
        let z = max(t.web.pageZoom, 0.1)
        let x = Double(local.x / z)
        let y = Double(local.y / z)
        let lines: [String] = [
            "(function(x,y){",
            "var e=document.elementFromPoint(x,y);",
            "if(!e){return 0;}",
            "var t=e.tagName;",
            "if(e.focus){e.focus();}",
            "if(t==='INPUT'||t==='TEXTAREA'||e.isContentEditable){return 2;}",
            "e.click();return 1;",
            "})(\(x),\(y))"
        ]
        t.web.evaluateJavaScript(lines.joined(), completionHandler: { [weak self] result, _ in
            if let n = result as? Int, n == 2 {
                DispatchQueue.main.async {
                    self?.app?.keyboard.open(.page, initial: "")
                }
            }
        })
    }

    func insertText(_ s: String) {
        let lines: [String] = [
            "(function(t){var e=document.activeElement;if(!e){return;}",
            "if(e.isContentEditable){document.execCommand('insertText',false,t);return;}",
            "if(e.value===undefined){return;}",
            "var s=e.selectionStart,en=e.selectionEnd,v=e.value;",
            "if(s===null||s===undefined){e.value=v+t;}",
            "else{e.value=v.slice(0,s)+t+v.slice(en);e.selectionStart=e.selectionEnd=s+t.length;}",
            "e.dispatchEvent(new Event('input',{bubbles:true}));",
            "})(" + jsString(s) + ")"
        ]
        currentTab?.web.evaluateJavaScript(lines.joined(), completionHandler: nil)
    }

    func backspacePage() {
        let lines: [String] = [
            "(function(){var e=document.activeElement;if(!e){return;}",
            "if(e.isContentEditable){document.execCommand('delete');return;}",
            "if(e.value===undefined){return;}",
            "var s=e.selectionStart,en=e.selectionEnd,v=e.value;",
            "if(s===null||s===undefined){e.value=v.slice(0,-1);}",
            "else if(s!==en){e.value=v.slice(0,s)+v.slice(en);e.selectionStart=e.selectionEnd=s;}",
            "else if(s>0){e.value=v.slice(0,s-1)+v.slice(s);e.selectionStart=e.selectionEnd=s-1;}",
            "e.dispatchEvent(new Event('input',{bubbles:true}));",
            "})()"
        ]
        currentTab?.web.evaluateJavaScript(lines.joined(), completionHandler: nil)
    }

    func enterPage() {
        let lines: [String] = [
            "(function(){var e=document.activeElement;if(!e){return;}",
            "var o={key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true};",
            "var ok=e.dispatchEvent(new KeyboardEvent('keydown',o));",
            "e.dispatchEvent(new KeyboardEvent('keypress',o));",
            "e.dispatchEvent(new KeyboardEvent('keyup',o));",
            "if(ok&&e.form){if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();}}",
            "})()"
        ]
        currentTab?.web.evaluateJavaScript(lines.joined(), completionHandler: nil)
        app?.keyboard.close()
    }
}

// MARK: - vista

struct WebHost: UIViewRepresentable {
    @ObservedObject var browser: BrowserModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        v.clipsToBounds = true
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        guard let tab = browser.currentTab else { return }
        if tab.web.superview !== v {
            for s in v.subviews { s.removeFromSuperview() }
            tab.web.frame = v.bounds
            tab.web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(tab.web)
        }
    }
}

struct BrowserWindow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var app: AppModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var kb: KeyboardModel
    let theme: Theme

    private func smallButton(_ id: String, _ icon: String, enabled: Bool = true, on: Bool = false) -> some View {
        Button(action: { menu.activate(id) }) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(on ? Color.white : theme.text)
                .frame(width: 36, height: 36)
                .background(Circle().fill(on ? theme.accent : theme.card))
                .overlay(Circle().fill(menu.hoverId == id ? theme.hover : Color.clear))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }

    var body: some View {
        let tab = browser.currentTab
        let urlText: String = (kb.isOpen && kb.target == .url) ? kb.text : (tab?.urlString ?? "")
        let hasTick = browser.tick >= 0
        return VStack(spacing: 6) {
            tabStrip
            HStack(spacing: 5) {
                smallButton("b:web:back", "chevron.left", enabled: tab?.web.canGoBack ?? false)
                smallButton("b:web:fwd", "chevron.right", enabled: tab?.web.canGoForward ?? false)
                smallButton("b:web:reload", (tab?.web.isLoading ?? false) ? "xmark" : "arrow.clockwise")
                Button(action: { menu.activate("b:web:url") }) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text(urlText.isEmpty ? "Pesquisar ou digitar endereço" : urlText)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(urlText.isEmpty ? theme.sub : theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(theme.card))
                    .overlay(Capsule().fill(menu.hoverId == "b:web:url" ? theme.hover : Color.clear))
                }
                .buttonStyle(PlainButtonStyle())
                .target("b:web:url")
                smallButton("b:web:star", browser.isBookmarked ? "star.fill" : "star", on: browser.isBookmarked)
                smallButton("b:web:menu", "ellipsis", on: browser.sub != .page)
            }
            .padding(.horizontal, 8)
            if let t = tab, t.web.isLoading {
                GeometryReader { g in
                    Capsule().fill(theme.accent)
                        .frame(width: max(6, g.size.width * CGFloat(t.web.estimatedProgress)), height: 3)
                }
                .frame(height: 3)
                .padding(.horizontal, 12)
            }
            content
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.panel.opacity(0.97)))
        .opacity(hasTick ? 1 : 1)
        .target("p:browser")
    }

    private var tabStrip: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { pair in
                        tabChip(pair.offset, pair.element)
                    }
                }
            }
            smallButton("b:web:newtab", "plus")
            smallButton("b:win:close", "xmark")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    private func tabChip(_ i: Int, _ tab: BrowserTab) -> some View {
        let sel = (i == browser.current)
        let tid = "b:web:tab:\(i)"
        let cid = "b:web:close:\(i)"
        let title = tab.displayTitle
        return HStack(spacing: 4) {
            Button(action: { menu.activate(tid) }) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .leading)
                    .padding(.leading, 10)
                    .frame(height: 32)
            }
            .buttonStyle(PlainButtonStyle())
            .target(tid)
            Button(action: { menu.activate(cid) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.sub)
                    .frame(width: 24, height: 32)
            }
            .buttonStyle(PlainButtonStyle())
            .target(cid)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(sel ? theme.hover : theme.card))
    }

    @ViewBuilder
    private var content: some View {
        switch browser.sub {
        case .page:
            WebHost(browser: browser)
                .target("p:web")
        case .menu:
            ScrollPanel(menu: menu) {
                BrowserMenuList(menu: menu, browser: browser, theme: theme)
            }
            .background(theme.panel)
        case .bookmarks:
            ScrollPanel(menu: menu) {
                BrowserListView(menu: menu, browser: browser, theme: theme, bookmarks: true)
            }
            .background(theme.panel)
        case .history:
            ScrollPanel(menu: menu) {
                BrowserListView(menu: menu, browser: browser, theme: theme, bookmarks: false)
            }
            .background(theme.panel)
        }
    }
}

struct BrowserMenuList: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var browser: BrowserModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 8) {
            ActionRow(menu: menu, theme: theme, action: "b:web:home", title: "Página inicial", subtitle: "", icon: "house.fill")
            ActionRow(menu: menu, theme: theme, action: "b:web:bookmarks", title: "Favoritos",
                      subtitle: "\(browser.bookmarks.count) salvos", icon: "star.fill")
            ActionRow(menu: menu, theme: theme, action: "b:web:history", title: "Histórico", subtitle: "", icon: "clock.fill")
            ToggleRow(menu: menu, theme: theme, action: "b:web:theater", title: "Visualização em teatro",
                      subtitle: "Janela do navegador maior", isOn: browser.theater)
            ChoiceRow(menu: menu, theme: theme, title: "Zoom da página",
                      options: [("b:web:zoom:0", "80%"), ("b:web:zoom:1", "100%"), ("b:web:zoom:2", "125%"), ("b:web:zoom:3", "150%")],
                      selected: browser.zoomIdx)
            ActionRow(menu: menu, theme: theme, action: "b:web:clear", title: "Limpar dados de navegação",
                      subtitle: "Cookies, cache e histórico", icon: "trash.fill")
            ActionRow(menu: menu, theme: theme, action: "b:web:closeall", title: "Fechar todas as guias",
                      subtitle: "", icon: "xmark.circle.fill")
            Text("Toque ou pince para clicar; arraste com a pinça para rolar a página.")
                .font(.system(size: 12 * s))
                .foregroundColor(theme.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(8)
    }
}

struct BrowserListView: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var browser: BrowserModel
    let theme: Theme
    let bookmarks: Bool

    var body: some View {
        let s = menu.ts
        let list = bookmarks ? browser.bookmarks : browser.history
        return VStack(spacing: 8) {
            if list.isEmpty {
                Text(bookmarks ? "Nenhum favorito ainda" : "Nenhum histórico ainda")
                    .font(.system(size: 14 * s))
                    .foregroundColor(theme.sub)
                    .padding(.top, 30)
            }
            ForEach(0..<list.count, id: \.self) { i in
                row(list[i], i, s)
            }
        }
        .padding(8)
    }

    private func row(_ item: [String], _ i: Int, _ s: CGFloat) -> some View {
        let id = "s:b:web:open:\(i)"
        let title = item.count > 0 ? item[0] : ""
        let url = item.count > 1 ? item[1] : ""
        return HStack(spacing: 6) {
            Button(action: { menu.activate(id) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14 * s, weight: .medium)).foregroundColor(theme.text).lineLimit(1)
                    Text(url).font(.system(size: 11 * s)).foregroundColor(theme.sub).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
                .hoverFX(menu, id, theme, 12)
            }
            .buttonStyle(PlainButtonStyle())
            .target(id)
            if bookmarks {
                let rid = "s:b:web:rmbm:\(i)"
                Button(action: { menu.activate(rid) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(theme.text)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(theme.card))
                        .hoverFX(menu, rid, theme, 20)
                }
                .buttonStyle(PlainButtonStyle())
                .target(rid)
            }
        }
    }
}
