type: Changed

**Custom elements are native** : the registry, definitions, upgrades and reactions (`CustomElementRegistry.define` / `get` / `getName` / `whenDefined` / `upgrade`, the `HTMLElement` constructor and the reaction queue) come from the engine (`runtime/custom_elements.c`) instead of prelude JavaScript (`prelude/customelements.js`), trimming the realm image. The state keeps the engine's Map / WeakMap / Set so element and constructor identity and the upgrade / reaction semantics are unchanged.
