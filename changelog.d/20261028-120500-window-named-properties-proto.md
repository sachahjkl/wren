type: Fixed

**Window named properties** (`globalThis`) : the named-properties object in the Window prototype chain is again an immutable-prototype exotic object — `Object.setPrototypeOf` to its current prototype succeeds, to anything else throws, and `Reflect.setPrototypeOf` returns false. QuickJS exotic classes cannot override `[[SetPrototypeOf]]`, so the native port now wraps the object in a C-trapped `Proxy` (no prelude JavaScript), as the former prelude did.
