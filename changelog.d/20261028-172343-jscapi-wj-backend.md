type: Added

**Colle JavaScript sur le moteur Odin** (`wj`, `src/engine/jscapi`) : l'API C de QuickJS (167 procédures : valeurs NaN-boxées, références comptées émulées sur le GC traçant, classes à données opaques, finaliseurs, cycles par `gc_mark`, objets exotiques, modules natifs) est implémentée sur `jsrt`. `-define:WJ_JSRT=true` fait pointer les noms de `wj` dessus sans toucher aux fichiers de domaine ; `-define:JSCAPI_EXPORT=true` l'exporte pour le C restant. Plan chiffré dans `docs/engine/jscapi.md`.
