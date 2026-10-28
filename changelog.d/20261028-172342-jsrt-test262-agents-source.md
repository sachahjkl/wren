type: Added

**Moteur JavaScript en Odin, conformité** (`jsrt`) : test262 passe à 100 % de ce que passe QuickJS-ng (43 233 sur 43 267 tests). `Function.prototype.toString` rend le vrai texte source, les `agent` de `$262` et `Atomics.wait` / `Atomics.notify` tournent sur des threads, `\p{RGI_Emoji}` et les propriétés de chaînes sont acceptés. Tableau et mesures dans `docs/engine/runtime.md`.
