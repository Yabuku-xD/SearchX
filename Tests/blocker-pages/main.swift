import AppKit
import WebKit

func read(_ n: String) -> String { (try? String(contentsOfFile: (ProcessInfo.processInfo.environment["LISTS"] ?? "/tmp/lists") + "/" + n, encoding: .utf8)) ?? "" }
let sources: [(group: String, text: String)] = [
  ("ads", read("filters.min.txt")), ("ads", read("badware.min.txt")), ("ads", read("quick-fixes.min.txt")),
  ("ads", read("unbreak.min.txt")), ("ads", read("easylist.txt")), ("ads", read("serverlist.phppgl.txt")),
  ("privacy", read("easyprivacy.txt")), ("privacy", read("privacy.min.txt")),
  ("security", read("urlhaus-filter-ag-online.txt")),
]
let out = FilterCompiler.compile(sources)
let store = WKContentRuleListStore(url: URL(fileURLWithPath: NSTemporaryDirectory() + "search-blocker-pages-store"))!

final class Probe: NSObject, WKUIDelegate, WKNavigationDelegate {
  var opens: [String] = []
  var map: [String: [[String]]] = [:]
  var top = ""
  var scripted = false
  var frameHosts = Set<String>()
  func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let h = a.request.url?.host()?.lowercased(), !(a.targetFrame?.isMainFrame ?? true) {
      frameHosts.insert(h)
      if scripted, map[h] == nil {
        let calls = Scriptlets.calls(for: h, top: top, in: out.scriptlets)
        map[h] = calls
        if !calls.isEmpty, let s = Scriptlets.source(byHost: map) {
          w.configuration.userContentController.removeAllUserScripts()
          w.configuration.userContentController.addUserScript(WKUserScript(source: s, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
      }
    }
    decisionHandler(.allow)
  }
  var done: (() -> Void)?
  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    opens.append(a.request.url?.absoluteString ?? "(blank)"); return nil
  }
}

var lists: [WKContentRuleList] = []
var pendingMap: [String: [[String]]] = [:]
func compileAll(_ then: @escaping () -> Void) {
  var left = out.lists.count
  for (g, j) in out.lists {
    let id = g + "-" + String(j.utf8.count)
    store.lookUpContentRuleList(forIdentifier: id) { found, _ in
      let fin: (WKContentRuleList?) -> Void = { l in if let l { lists.append(l) } else { print("FAILED", g) }; left -= 1; if left == 0 { then() } }
      if let found { fin(found) } else { store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: j) { l, e in if e != nil { print(g, e!) }; fin(l) } }
    }
  }
}

let sites = CommandLine.arguments.dropFirst().map { URL(string: $0)! }
var results: [[String: Any]] = []
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)

func run(_ i: Int, blocked: Bool, next: @escaping () -> Void) {
  let conf = WKWebViewConfiguration()
  conf.websiteDataStore = .nonPersistent()
  conf.preferences.javaScriptCanOpenWindowsAutomatically = false
  let url = sites[i]
  if blocked {
    lists.forEach(conf.userContentController.add)
    let host = url.host()!.lowercased()
    pendingMap = [host: Scriptlets.calls(for: host, in: out.scriptlets)]
    if let s = Scriptlets.source(byHost: pendingMap) {
      conf.userContentController.addUserScript(WKUserScript(source: s, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }
  }
  let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: conf)
  web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
  window.contentView = web
  let probe = Probe()
  probe.top = url.host()!.lowercased(); probe.scripted = blocked; probe.map = blocked ? pendingMap : [:]
  web.uiDelegate = probe
  web.navigationDelegate = probe
  web.load(URLRequest(url: url))
  DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
    // Clicks anywhere on the page, as a person would, five times.
    for k in 0..<6 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.6) {
        let p = NSPoint(x: 200 + k * 150, y: 250 + (k % 3) * 120)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: k, clickCount: 1, pressure: 1) {
            if type == .leftMouseDown { web.mouseDown(with: e) } else { web.mouseUp(with: e) }
          }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      web.evaluateJavaScript("(function(){var b=document.body,best=1e9,all=[];for(var i=0;i<12;i++){var t=performance.now();b.style.display='none';b.offsetHeight;b.style.display='';b.offsetHeight;var d=performance.now()-t;all.push(d);}all.sort(function(a,c){return a-c});window.__restyle={median:all[6],count:document.getElementsByTagName('*').length};})();JSON.stringify({restyle: window.__restyle, res: performance.getEntriesByType('resource').map(function(e){try{return new URL(e.name).hostname}catch(x){return ''}}), frames: Array.from(document.querySelectorAll('iframe')).map(function(f){return f.src}).filter(Boolean), url: location.href})") { value, error in
        let json = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let hosts = (json["res"] as? [String]) ?? []
        let page = url.host()!.lowercased()
        let third = hosts.filter { !$0.hasSuffix(page.replacingOccurrences(of: "ww4.", with: "")) }
        var counts: [String: Int] = [:]; third.forEach { counts[$0, default: 0] += 1 }
        results.append(["site": url.absoluteString, "blocked": blocked, "requests": hosts.count, "thirdPartyRequests": third.count,
                        "thirdPartyHosts": counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" },
                        "restyle": json["restyle"] ?? [:], "popupAttempts": probe.opens, "frameHosts": probe.frameHosts.sorted(), "scriptletHosts": probe.map.filter { !$0.value.isEmpty }.keys.sorted(), "iframes": json["frames"] ?? [], "error": error.map { "\($0)" } ?? ""])
        web.removeFromSuperview()
        next()
      }
    }
  }
}

func sequence(_ i: Int) {
  guard i < sites.count * 2 else {
    let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT"] ?? "blocker-pages.json")); print(String(data: data, encoding: .utf8)!); exit(0)
  }
  run(i / 2, blocked: i % 2 == 1) { sequence(i + 1) }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let t = Date()
compileAll { print("lists ready", lists.count, Int(Date().timeIntervalSince(t)), "s"); sequence(0) }
app.run()
