type: Added

**`navigator.userActivation`** (`UserActivation`, `isActive`, `hasBeenActive`) : the document's user-activation state, read natively from the activation-triggering input the browser already tracks. `isActive` is true within the transient activation window of a recent click or key press (`security.webauthn.user_activation_ms`); `hasBeenActive` is the sticky flag that turns true at the first such input and never expires, so sites can gate features on a real user gesture through the standard API.
