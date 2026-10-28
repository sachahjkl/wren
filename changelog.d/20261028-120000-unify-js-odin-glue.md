type: Changed

**Colle JS en Odin (`native/js/odin`)** : la couche d'aide `wj` est unifiée (un fichier par thème, chaque symbole déclaré une seule fois) et le build redevient vert avec les ports des cinq agents G1–G5.
  - Les imports du navigateur (`wr_*`) ne sont plus tapés à la main : ils viennent du fichier généré `native/js/odin/wj/wr_imports.odin` (`bindgen`, émis dans les deux modes).
  - Les structures C du moteur (`wj_obj`, `wj_realm`, `wj_interface`, `wj_listener`, `dom_impl`…) sont reflétées en Odin et lues sur place ; `wj_shim.c` ne contient plus aucun code, seulement les `_Static_assert` de leurs décalages (les trois shims et leurs accesseurs par champ disparaissent).
  - `qjs_convert`, `buffer` et `promise` (aides de `wj.h` implémentées en Odin) rejoignent le paquet `wj` : tous les domaines les appellent `wj.wj_to_str`, `wj.wj_to_buffer_source`…
  - Corrigés au passage : `popover` lisait une table globale jamais initialisée (`HTMLElement.popover` rendait `""`), `customElements.whenDefined` tronquait un nom à un NUL, les messages d'erreur de `customElements.define` sont ceux de l'implémentation C, `JS_IsString` / `JS_IsBigInt` reconnaissent les cordes et les petits BigInt, `JS_UNINITIALIZED` a la bonne étiquette.
