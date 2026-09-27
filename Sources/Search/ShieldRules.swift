import Foundation

// What the blocker blocks, as the content-blocker JSON WebKit compiles into
// its networking — before a request is made, before a stylesheet applies, and
// with nothing put into the page. Kept apart from Shield, which hands it to
// WebKit on the Mac, because the same JSON is what WebKitGTK compiles on Linux
// (see PORTING.md).
//
// Shaped after uBlock Origin's default setup — its own filters, EasyList,
// EasyPrivacy and Peter Lowe's list of ad servers — within what WebKit's own
// blocker can express, and at a size that suits a browser of a few megabytes:
//
//   - third-party requests to ad and tracking servers, blocked outright;
//   - pop-up and pop-under networks, blocked as a whole, the way uBO's $all
//     does it: no window of theirs opens, no request reaches them, and no
//     page can send itself there;
//   - a short list of slots that are always an advertisement, hidden;
//   - the tracking parameters uBO's removeparam filters take off addresses,
//     taken off a page's address before it loads (see Shield.cleaned).
//
// uBO's redirects to neutered scripts have no WebKit counterpart, so a script
// sites wait on before they work is left to its site rather than broken: the
// lists are of servers whose loss a page does not notice. They are written for
// Search rather than copied from filter lists, and deliberately short: every
// domain here is one uBO's default lists block too.
//
// uBO's other default, turning off hyperlink auditing (<a ping>), needs no
// rule: WebKit here sends no such pings. Beacons are no separate type to
// WebKit's blocker, so a beacon to a tracker is stopped by its domain above.

enum ShieldRules {
    /// Third parties whose only job is to show an advertisement. First-party
    /// requests are untouched: a site's own scripts are the site.
    static let ads = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "adservice.google.com", "amazon-adsystem.com",
        "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "taboola.com",
        "outbrain.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "smartadserver.com", "sharethrough.com", "indexww.com",
        "bidswitch.net", "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "adform.net", "advertising.com", "yieldmo.com", "triplelift.com",
        "3lift.com", "sovrn.com", "lijit.com", "gumgum.com", "media.net",
        "contextweb.com", "onetag-sys.com", "emxdgt.com", "rhythmone.com",
        "spotxchange.com", "springserve.com", "undertone.com", "zemanta.com",
        "mgid.com", "revcontent.com", "adblade.com", "nativo.com", "adzerk.net",
        "kargo.com", "seedtag.com", "richaudience.com", "improvedigital.com",
        "adition.com", "smaato.net", "yieldlab.net", "adscale.de", "primis.tech",
        "connatix.com", "vidazoo.com", "aniview.com", "adthrive.com",
        "ezoic.net", "ezojs.com", "serving-sys.com", "flashtalking.com",
        "innovid.com", "doubleverify.com", "adsafeprotected.com", "moatpixel.com",
        "btloader.com", "getadmiral.com", "infolinks.com", "bidvertiser.com",
        "adskeeper.com", "a-ads.com", "coinzilla.io", "bitmedia.io",
        "ads.yahoo.com", "ads.linkedin.com", "carbonads.net", "buysellads.com",
        "e-planning.net", "smilewanted.com", "adkernel.com", "rtbhouse.com",
        "creativecdn.com", "tremorhub.com", "unrulymedia.com", "adpushup.com",
        "adocean.pl",
    ]

    /// Third parties that watch: analytics, session recording, data brokers.
    static let trackers = [
        "google-analytics.com", "googletagmanager.com", "analytics.google.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com", "chartbeat.net",
        "hotjar.com", "hotjar.io", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "mxpnl.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        "bat.bing.com", "px.ads.linkedin.com", "snap.licdn.com", "sc-static.net",
        "tr.snapchat.com", "ct.pinterest.com", "nr-data.net", "js-agent.newrelic.com",
        "heapanalytics.com", "crazyegg.com", "luckyorange.com", "luckyorange.net",
        "inspectlet.com", "smartlook.com", "lr-ingest.io", "statcounter.com",
        "histats.com", "getclicky.com", "kissmetrics.io", "omtrdc.net",
        "demdex.net", "everesttech.net", "2o7.net", "krxd.net", "bluekai.com",
        "exelator.com", "rlcdn.com", "agkn.com", "crwdcntrl.net", "tapad.com",
        "liadm.com", "mathtag.com", "eyeota.net", "bizible.com", "mktoresp.com",
        "hs-analytics.net", "hsadspixel.net", "cloudflareinsights.com",
        "mc.yandex.ru", "top-fwz1.mail.ru", "counter.yadro.ru",
        "bounceexchange.com", "clicktale.net", "contentsquare.net",
        "quantummetric.com", "sessioncam.com", "id5-sync.com", "zeotap.com",
        "permutive.com", "permutive.app", "lotame.com",
    ]

    /// Pop-up and pop-under networks, and the malvertising that rides them.
    /// Blocked as a whole: as a window a page opens, as a page of its own,
    /// and as any request (uBO's $all, $popup and $popunder).
    static let popups = [
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com",
        "onclickads.net", "onclasrv.com", "adsterra.com", "adsterratech.com",
        "exoclick.com", "exosrv.com", "clickadu.com", "hilltopads.net",
        "ad-maven.com", "admaven.com", "galaksion.com", "monetag.com",
        "trafficstars.com", "juicyads.com", "adcash.com", "zeropark.com",
        "evadav.com", "richads.com", "pushground.com", "clickaine.com",
        "popmyads.com", "adxpansion.com", "trafficjunky.net", "tsyndicate.com",
        "realsrv.com",
    ]

    /// The slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[data-google-query-id]", "[data-ad-client]",
        "amp-ad", "amp-sticky-ad", "amp-embed[type=\"taboola\"]",
        "[id^=\"taboola-\"]", "#taboola-below-article", ".trc_rbox_container",
        ".OUTBRAIN", ".ob-widget", "[id^=\"rc-widget-\"]", ".mgbox",
        "[id^=\"ezoic-pub-ad\"]", ".ezoic-ad", "[id^=\"AdThrive_\"]", ".adthrive-ad",
        "#carbonads", "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]", "iframe[src*=\"adnxs.com\"]",
        "iframe[src*=\"taboola.com\"]", "iframe[src*=\"outbrain.com\"]",
    ]

    // AS uses these ad-server attributes on its empty slot containers.
    // Scope the selector to that site; generic class names can hide articles.
    static let wrappers: [(domain: String, selector: String)] = [
        ("en.as.com", "div.ad[data-adtype][data-slot=\"/7811748/as_mob/google/en\"]"),
    ]

    /// Query parameters that only say where a click came from, as uBO's
    /// removeparam filters take them off: never part of what a page shows.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid",
        "mc_cid", "mc_eid", "igshid", "yclid", "_hsenc", "_hsmi", "mkt_tok",
        "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "twclid", "ttclid",
        "li_fat_id", "srsltid", "_openstat", "wickedid", "ns_mchannel",
        "ns_source", "ns_campaign", "ns_linkname", "ns_fee", "s_cid", "ef_id",
        "epik", "rb_clickid", "irclickid", "__hsfp", "__hssc", "__hstc",
    ]

    /// utm_source, utm_medium and the rest of Google's campaign family.
    static func isTracking(parameter name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || trackingParameters.contains(name)
    }

    /// The host is one of `list`'s, or under one.
    static func host(_ host: String?, isIn list: [String]) -> Bool {
        guard var host = host?.lowercased() else { return false }
        while true {
            if list.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
        }
    }

    /// The rules, encoded. Nil only if encoding them fails.
    static func json() -> String? {
        func filter(_ domain: String) -> String {
            "^[a-z]+://([^/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
        }
        var rules: [[String: Any]] = []
        for domain in Set(ads + trackers).sorted() {
            rules.append([
                "trigger": ["url-filter": filter(domain), "load-type": ["third-party"]],
                "action": ["type": "block"],
            ])
        }
        for domain in popups {
            rules.append([
                "trigger": ["url-filter": filter(domain)],
                "action": ["type": "block"],
            ])
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": slots.joined(separator: ", ")],
        ])
        // Each wrapper, scoped to the domain its markup was read from: a
        // selector that applies to one site cannot reach another's page.
        for wrapper in wrappers {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*" + wrapper.domain]],
                "action": ["type": "css-display-none", "selector": wrapper.selector],
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }
}
