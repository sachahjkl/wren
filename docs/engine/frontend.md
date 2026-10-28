# Moteur JavaScript — front-end E1 (`src/engine/frontend`)

Le paquet `frontend` est la moitié « amont » du moteur JavaScript écrit en Odin. Il transforme du source
ECMAScript en **bytecode QuickJS-ng 0.17**, identique octet pour octet à ce que produit `JS_WriteObject`
(`BC_VERSION 28`, drapeaux `JS_WRITE_OBJ_BYTECODE | JS_WRITE_OBJ_STRIP_SOURCE`). L'autre moitié (E2 : valeurs,
objets, GC, interpréteur, fonctions natives) relit ce bytecode. Les deux moitiés ne se rencontrent qu'au
**format de bytecode** : `opcodes.odin`, `atoms.odin`, `serialize.odin`.

Le paquet compile pour `windows_amd64`, `linux_amd64` et `freestanding_wasm32`. Toute allocation passe par
l'allocateur injecté (une arène libère une compilation entière d'un coup). Aucun appel OS, aucune libc. Il
réutilise les paquets feuilles `numconv` (littéraux numériques) et `unicode` (`ucd`, données Unicode 17.0.0).

## Pourquoi un portage direct du compilateur QuickJS

La première version passait par un AST (lexer, parseur, résolveur, émetteur séparés ; voir l'historique git,
commit `dc13ba87`). Elle ne pouvait pas atteindre la parité octet : QuickJS émet en **une seule passe** pendant le
parse, et son bytecode dépend de cet ordre exact. Exemples : les réécritures du dernier opcode émis
(`get_lvalue`, `optional chaining`, `delete`), l'ordre de création des variables et des portées, les
`OP_scope_get_var` posés avant que la portée ne soit connue, les labels numérotés dans l'ordre d'émission, les
`line_num` pris au moment du jeton. Un AST impose un autre ordre. Le paquet suit donc la structure de
`quickjs.c` (parse + émission, puis `resolve_variables`, `resolve_labels`, `compute_stack_size`), réécrite en
Odin idiomatique :

- `JS_Value` est une `union` exhaustive (entier, flottant, chaîne, BigInt, fonction, gabarit) au lieu d'un
  `JSValue` à étiquette ; chaque `switch` est vérifié par le compilateur.
- Les chaînes sont des `String_Value` (Latin-1 ou UTF-16, comme `JSString`) sans comptage de références.
- Les erreurs suivent le modèle « la première gagne » de QuickJS mais sans `longjmp` ni exception : chaque
  procédure renvoie `bool` (erreur) comme dans le C, ce qui garde le portage lisible ligne à ligne.
- Pas de GC ni de libération : tout vit dans l'arène de la compilation.

## Fichiers

| Fichier | Rôle |
|---|---|
| `compile.odin` | Entrées publiques (`compile_program`, `compile_script`, `compile_module`, `write_object_of`), littéraux regexp |
| `js_defs.odin` | Jetons, `Func_Def`, `Function_Bytecode`, `Module_Def`, `Parse_State`, garde de pile |
| `js_value.odin` | `String_Value`, `JS_Value`, `String_Buffer`, décodage UTF-8 |
| `js_lex.odin` | Lexer (`next_token`, chaînes, gabarits, nombres, regexp, `lre_parse_escape`) |
| `js_emit.odin` | Émission, labels, portées, variables (`emit_op`, `push_scope`, `add_var`…) |
| `js_expr.odin`, `js_expr2.odin` | Expressions, déstructuration, affectations, appels, classes |
| `js_stmt.odin` | Instructions |
| `js_func.odin` | Fonctions (`js_parse_function_decl2`, paramètres, corps) |
| `js_module.odin` | `import` / `export`, attributs d'import |
| `js_resolve.odin`, `js_passes.odin` | `resolve_variables`, `resolve_labels` (peephole compris), `compute_stack_size`, `js_create_function` |
| `js_regexp.odin` | Compilateur de regexp de libregexp (`lre_compile`) |
| `atoms.odin` | Atomes prédéfinis (ordre de `quickjs-atom.h`) et atomes runtime |
| `opcodes.odin` | Table des opcodes (`quickjs-opcode.h`) |
| `serialize.odin` | Flux `JS_WriteObject` |

## Littéraux regexp

QuickJS stocke dans le pool de constantes, pour chaque littéral regexp, la chaîne du motif **et** le bytecode
libregexp compilé, puis émet `OP_regexp`. Le verdict de syntaxe d'une regexp fait donc partie du verdict du
script. `js_regexp.odin` porte `lre_compile` (parseur et émetteur) avec ses particularités qui se voient dans les
octets :

- les intervalles de caractères suivent `CharRange` de libunicode (un ensemble inversé finit à `0xFFFFFFFF`) ;
- `\p{gc=…}` reconstruit la segmentation de la table `unicode_gc_table` (une plage par suite de même catégorie,
  plus les suites alternées Lu/Ll), car libunicode ajoute ces plages sans les fusionner ;
- les ensembles de chaînes (`v`) gardent l'ordre de la table de hachage et du tri `rqsort` de `cutils.h` ;
- le pliage de casse reprend les exceptions de libunicode (U+FB05, U+FB06).

## Garde de pile

`Compile_Options.stack_budget` (octets, défaut 512 Kio) borne la pile que la compilation utilise sous son point
d'entrée, comme `js_check_stack_overflow`. Toutes les récursions (expressions, instructions, fonctions,
`js_create_function`, regexp) vérifient l'adresse d'une variable locale ; au-delà, la compilation échoue avec
« stack overflow » au lieu de planter. Sur wasm32, cette variable vit dans la pile fantôme (celle qui
déborderait). `max_nesting` (défaut 6000) reste une seconde borne en nombre d'appels.

## Outils de parité (`judge/`, `tools/e1_*.ps1`)

- `build\e1j.exe emit|emit-module <f.js> <out.bin>` : le flux `JS_WriteObject`.
- `build\e1j.exe batch <manifest> <dir>` puis `diff-batch <manifest> <refdir> <ourdir>` : tableau par dossier
  (fichiers compilés des deux côtés, identiques, erreurs d'un seul côté, différences de taille ou de compteurs).
- `build\e1j.exe decode <bin>` : désassemblage lisible ; `tools\e1_diff.ps1 <f.js>` compare un fichier.
- `build\e1j.exe speed <f.js> [iters]` : MB/s de compilation ; `prof <f.js> [iters]` : profileur par
  échantillonnage (Windows).
- `build\e1j.exe fuzz <fichiers | @manifest>` : mutations (octets, collages, troncatures, duplications) et
  entrées pathologiques (imbrications profondes) ; rapporte la compilation la plus lente et le ratio mémoire max.
- `tools\e1_run.ps1` : reconstruit le juge, compare le corpus positif `test262/test/language` et les verdicts du
  corpus négatif (syntaxe) contre l'oracle C `bc_dump.exe` (QuickJS-ng 0.17 compilé avec zig, avec un chargeur
  de modules vide pour que les `import` se résolvent sans exécuter).

## Résultats (test262, 2026-10-28)

- `test/language`, positifs : 19 272 fichiers, 19 006 compilés des deux côtés, **19 006 identiques (100 %)** ;
  les 266 autres sont rejetés par les deux moteurs (fonctionnalités que QuickJS-ng 0.17 n'a pas).
- `test/language`, négatifs de syntaxe : **4 452 verdicts sur 4 452 identiques**.
- `test/` complet (48 949 positifs + harness) : 48 620 identiques sur 48 623 compilés (99,99 %) ; 46 fichiers
  rejetés par nous seulement (propriétés de chaînes Unicode `\p{RGI_Emoji}`…, voir « Reste à faire ») ; 4 658
  négatifs, tous les verdicts identiques.
- Vitesse : du même ordre que QuickJS (0,9× à 1,15× selon le fichier, compilation seule, sans sérialisation).

## Reste à faire

- Propriétés de chaînes du drapeau `v` (`Basic_Emoji`, `RGI_Emoji*`, `Emoji_Keycap_Sequence`) : il faut les
  données `emoji-sequences.txt` / `emoji-zwj-sequences.txt` dans `ucd`, puis reproduire l'ordre d'insertion de
  libunicode. 46 fichiers de `built-ins/RegExp`.
- `Changes_When_Casemapped/Lowercased/Uppercased` : libunicode énumère les entrées de `case_conv_table1` sans les
  fusionner ; il faut reconstruire cette segmentation (`unicode_gen.c`, `find_run_type`). 3 fichiers.

## Ce que E2 doit savoir

- Entrée : `compile_program(src, .script | .module, alloc, opts)` puis `write_object_of(res, alloc)`.
- Une regexp littérale donne deux constantes : la chaîne du motif puis le bytecode libregexp (chaîne Latin-1),
  puis `OP_regexp`. L'exécuteur de regexp de E2 doit lire le format libregexp (pas celui de `wb:engine/regexp`).
- Un module est un enregistrement `BC_TAG_MODULE` qui enveloppe la fonction.
- Objets gabarit : `TEMPLATE_OBJECT(cuits…, TEMPLATE_OBJECT(bruts…, UNDEFINED))`.
- BigInt du pool : limbes de 32 bits, complément à deux, sans limbe redondant.
- `PREDEFINED_ATOMS` doit rester dans l'ordre de `quickjs-atom.h`. `Private_brand` et les `Symbol.*` sont des
  symboles : une chaîne ne leur correspond jamais.
- Régler `stack_budget` selon la pile restante de l'appelant (la cible wasm a une pile de 1 Mio).
