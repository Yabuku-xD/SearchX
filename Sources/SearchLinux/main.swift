import CWebKitGTK

// Search on Linux: GTK 4 around the page, WebKitGTK for the page. The start
// of the port described in PORTING.md.

private var browser: Browser?

// A test run is an application of its own, or launching one while the real
// browser is open would only bring the real one forward.
let identity = Folder.testing ? "com.shyamalankannan.searchx.test" : "com.shyamalankannan.searchx"
let application = gtk_application_new(identity, G_APPLICATION_DEFAULT_FLAGS)!
on(raw(application), "activate") {
    // A second launch activates the first, which already has its window.
    guard browser == nil else { return }
    browser = Browser(application: application)
}
let status = g_application_run(search_application(raw(application)), CommandLine.argc, CommandLine.unsafeArgv)
Session.flush()
g_object_unref(raw(application))
exit(status)
