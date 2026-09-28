import Foundation

// Pages the blocker's own additions never touch: signing in, passkeys,
// captchas and paying. uBO's lists already rarely break these; what is added
// on top of them here — procedural filters, your filters, dynamic rules,
// parameter removal, CSP, header and response rules, redirect stand-ins —
// is exactly the kind of thing that can, and a checkout that half-loads or a
// sign-in window that never answers costs far more than an ad seen.
//
// Two ways a page is protected, both from its address alone, decided before
// it loads:
//   • it is on a host whose job is one of those things (a sign-in provider,
//     a payment service, a captcha, an account-security page);
//   • its path says it is doing one of them (/login, /checkout, /passkey…).
// A frame is protected by its own host: Stripe's card field inside any shop.

enum Protected {
    /// Hosts, and everything under them, that sign in, pay or check you're
    /// a person. Sign-in providers also come from Intent.signIn.
    nonisolated static let hosts: [String] = [
        // Signing in
        "accounts.google.com", "accounts.youtube.com", "myaccount.google.com", "passwords.google.com",
        "appleid.apple.com", "idmsa.apple.com", "iforgot.apple.com",
        "login.microsoftonline.com", "login.live.com", "login.microsoft.com", "account.live.com", "login.windows.net",
        "auth0.com", "okta.com", "oktapreview.com", "onelogin.com", "duosecurity.com", "clerk.com", "clerk.dev",
        "stytch.com", "workos.com", "id.atlassian.com", "auth.atlassian.com", "identitytoolkit.googleapis.com",
        "securetoken.googleapis.com", "login.yahoo.com", "id.twitch.tv", "accounts.spotify.com",
        // Paying
        "stripe.com", "stripe.network", "stripecdn.com", "paypal.com", "paypalobjects.com", "braintreegateway.com",
        "braintree-api.com", "venmo.com", "adyen.com", "adyenpayments.com", "checkout.com", "squareup.com",
        "squarecdn.com", "square.site", "klarna.com", "klarnaservices.com", "affirm.com", "afterpay.com",
        "clearpay.co.uk", "sezzle.com", "shop.app", "shopifycs.com", "pay.shopify.com", "checkout.shopify.com",
        "pay.google.com", "payments.google.com", "apple-pay-gateway.apple.com", "applepay.cdn-apple.com",
        "pay.amazon.com", "payments.amazon.com", "authorize.net", "worldpay.com", "globalpay.com", "cybersource.com",
        "recurly.com", "chargebee.com", "paddle.com", "paddle.net", "lemonsqueezy.com", "razorpay.com", "mollie.com",
        "gocardless.com", "plaid.com", "wise.com", "revolut.com",
        // 3-D Secure and card checks
        "cardinalcommerce.com", "3dsecure.io", "arcot.com", "securecode.com", "verifiedbyvisa.com",
        // Captchas
        "recaptcha.net", "hcaptcha.com", "challenges.cloudflare.com", "arkoselabs.com", "funcaptcha.com",
    ]

    /// Places on any site whose path says it signs in, sets up a passkey or
    /// takes a payment. Matched as the start of a path segment.
    nonisolated static let words: [String] = [
        "login", "log-in", "signin", "sign-in", "sign_in", "signup", "sign-up", "register", "auth", "oauth",
        "sso", "saml", "openid", "passkey", "webauthn", "2fa", "mfa", "two-factor", "verify", "security",
        "checkout", "payment", "pay", "billing", "purchase", "buy", "cart", "basket", "order", "wallet",
        "subscribe", "subscription", "donate", "ap", "ax",
    ]

    /// Google's own captcha lives on google.com; its path is the tell.
    nonisolated static let paths: [(host: String, path: String)] = [
        ("google.com", "/recaptcha"), ("gstatic.com", "/recaptcha"),
    ]

    /// Whether a host is one of the protected ones, or under one.
    nonisolated static func host(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether a document at this address is left alone.
    nonisolated static func page(_ url: URL?) -> Bool {
        guard let url else { return false }
        let hostName = url.host()?.lowercased()
        if host(hostName) || Intent.signIn(url) { return true }
        let path = url.path.lowercased()
        if let hostName, paths.contains(where: { entry in
            (hostName == entry.host || hostName.hasSuffix("." + entry.host)) && path.hasPrefix(entry.path)
        }) {
            return true
        }
        let segments = path.split(separator: "/")
        return segments.contains { segment in
            words.contains { word in
                segment == word || (segment.hasPrefix(word) && segment.dropFirst(word.count).first.map { "-_.".contains($0) } == true)
            }
        }
    }

    /// WebKit rules, last in a list, that undo what came before it: every
    /// load from a protected host, anywhere, and everything on a protected
    /// page. WebKit's rule regexes have no alternation, so one each.
    /// \`pages: false\` for uBO's lists: only the hosts, so an ad on a login
    /// page is still blocked; the new parts (your filters, dynamic rules)
    /// stand down on the whole page.
    nonisolated static func rules(pages: Bool = true) -> [String] {
        func escaped(_ host: String) -> String { host.replacingOccurrences(of: ".", with: #"\."#) }
        let start = #"^[a-z][a-z0-9.+-]*://([^/?#]*\.)?"#
        let hostPatterns = hosts.map { start + escaped($0) + "[:/?#]" }
            + paths.map { start + escaped($0.host) + "(:[0-9]+)?" + $0.path }
        let pagePatterns = hostPatterns + words.flatMap { word -> [String] in
            let at = #"^https?://[^/?#]*/([^?#]*/)?"# + word.replacingOccurrences(of: "-", with: #"\-"#)
            return [at + "[-_./?#]", at + "$"]
        }
        let undo = ["type": "ignore-previous-rules"]
        let rules: [[String: Any]] = hostPatterns.map { ["action": undo, "trigger": ["url-filter": $0]] }
            + (pages ? [["action": undo, "trigger": ["url-filter": ".*", "if-top-url": pagePatterns]]] : [])
        return rules.compactMap { rule in
            (try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
