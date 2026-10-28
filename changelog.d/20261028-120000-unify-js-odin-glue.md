type: Changed

**JS engine glue (`native/js/odin`)** : the Odin helper layer is unified into one `wj` package with a single declaration per symbol (QuickJS API, `wj_*`/`web_*` imports, strings, values, errors) and a single C field-accessor shim (`wj_shim.c`), replacing the four per-agent files (`wj_g2/g3/g5.odin`, `wj_g2_shim.c`) that redeclared the same symbols and broke the build.
