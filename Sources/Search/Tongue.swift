import SwiftUI

// The words on the screen, in whatever language the Mac speaks.
//
// English is not stored anywhere: a panel's own sentence is the lookup key,
// and a language file beside the binary replaces the sentences it knows.
// Keys a language has never heard pass through untouched, which is why
// English needs no file at all — and why a translation can be added a page
// at a time. The tables live in ../Localization, copied into the app bundle
// by build.sh; LocalizedStringKey does the rest.
//
// Text(_:) and Button(_:) fed a string literal already look themselves up.
// `.said` is for the plainer path — a String carried in from the caller —
// which SwiftUI otherwise draws as it was given.

extension String {
    /// The sentence, as the screen reads it through the language files.
    var said: LocalizedStringKey { LocalizedStringKey(self) }

    /// The sentence already resolved to plain text — for the places a
    /// sentence must stay a String (a tab's label, a window title) rather
    /// than become a view. Looked up now, at the source, where the words
    /// are known to be the app's own and not some page's title.
    var saidNow: String { NSLocalizedString(self, value: self, comment: "") }
}

/// Which language those sentences come out in: the Mac's. The system's own
/// list of languages (System Settings › General › Language & Region, or the
/// per-app choice there) is what the bundle reads, so there is nothing to
/// choose inside the app. A language with no table falls back to English.
enum Tongue {
    /// Removes the per-app language an older version's picker wrote, once.
    /// That picker left its own record under `app.language`; without it, an
    /// `AppleLanguages` entry is the one System Settings writes when the
    /// person picks a language for this app there, and it stays.
    static func followMac(_ store: UserDefaults) {
        guard store.object(forKey: "app.language") != nil else { return }
        store.removeObject(forKey: "app.language")
        let domain = Bundle.main.bundleIdentifier ?? ""
        if var own = UserDefaults.standard.persistentDomain(forName: domain), own["AppleLanguages"] != nil {
            own.removeValue(forKey: "AppleLanguages")
            UserDefaults.standard.setPersistentDomain(own, forName: domain)
        }
    }
}
