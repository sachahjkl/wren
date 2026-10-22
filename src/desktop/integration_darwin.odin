package desktop

// macOS: a stub, on purpose. What macOS lists is an application bundle: a Wren.app folder with an Info.plist that
// declares CFBundleURLTypes (http, https) and CFBundleDocumentTypes, registered with Launch Services (lsregister).
// Wren is one executable outside any bundle, and the things that would make it a candidate in System Settings >
// Desktop & Dock > Default web browser all belong to a bundle. Making one under ~/Applications that only wraps the
// executable is possible, and would be this backend's `install` (the bundle is the mark; `remove` deletes that folder);
// it needs a Mac to be tested, and Wren does not compile there yet, so no half-working version is shipped. `supported`
// says false and the shell hides the box.

@(private)
platform_backend :: proc() -> ^Backend { return nil }

set_process_identity :: proc(id: Identity) {}
