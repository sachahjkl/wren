// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=storageaccess order=48 exposed=Window
/// The Storage Access API (src/page/storage_access.odin): a frame of another site than its tab's, whose storage and
/// cookies are its partition of the tab's site (storage.partitioned), asks for its own: document.hasStorageAccess(),
/// document.requestStorageAccess(). Granted per (its site, the tab's site) for the session, by the person (a prompt over
/// the page) or by storage.access_requests; its requests then say so (Sec-Fetch-Storage-Access).
package api_js_storage_access

/// document.hasStorageAccess(): a promise of true when the document uses its unpartitioned storage and cookies (a
/// first-party document always does), false else.
//@wb fn
Document_hasStorageAccess :: proc() -> Promise

/// document.requestStorageAccess(): resolves once the document uses its unpartitioned storage and cookies; rejects
/// with NotAllowedError when it is refused (no user gesture, a sandbox without
/// allow-storage-access-by-user-activation, the storage-access permission policy, the person or the preference).
//@wb fn
Document_requestStorageAccess :: proc() -> Promise

