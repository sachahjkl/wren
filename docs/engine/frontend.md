# Moteur JavaScript — front-end E1 (`src/engine/frontend`)

Le paquet `frontend` est la moitié « amont » du moteur JavaScript écrit en Odin : il transforme du source
ECMAScript en **bytecode QuickJS-ng 0.17**, compatible octet pour octet avec ce que produit `JS_WriteObject`
(`BC_VERSION 28`). L'autre moitié (E2 : valeurs, objets, GC, interpréteur, fonctions natives) relit ce bytecode.
Les deux moitiés ne se rencontrent qu'au **format de bytecode** : `opcodes.odin`, `atoms.odin`, `serialize.odin`.

Le paquet compile pour `windows_amd64`, `linux_amd64` et `freestanding_wasm32` (sandbox Wasm conservé). Toute
allocation passe par un allocateur injecté (une arène libère un parse entier d'un coup) ; aucun appel OS, aucun
libc. Il réutilise les briques feuilles déjà livrées : `numconv` (littéraux numériques via `atod`), `unicode`
(`ucd` : `is_id_start/continue`, espaces, pliage de casse), `regexp` (validation des littéraux regexp), `bigint`.

## Architecture

Le pipeline (câblé dans `compile.odin`) :

```
source
  → Lexer            (lexer.odin)        jetons, positions ligne/colonne, valeurs cuites
  → Parser           (parser*.odin)      AST + erreurs précoces
  → Resolver         (resolve.odin)      portées, genres de variables, this/arguments
  → Emitter          (emit.odin, compile.odin)  bytecode + labels
  → resolve_labels   (emit.odin)         backpatch des sauts
  → compute_stack_size (emit.odin)       taille de pile (exploration BFS, fidèle à QuickJS)
  → Func_Scope                           le JSFunctionBytecode
  → serialize        (serialize.odin)    le flux JS_WriteObject
```

### Ce qu'on « fait en Odin »

- **AST en tagged unions** (`Expr`, `Stmt`, `Pattern` sont des `union` d'Odin) sur arène : un `switch` est
  exhaustif, le compilateur vérifie qu'on traite chaque forme. Pas de champ `tag` manuel, pas de vtables, pas de
  libération par nœud.
- **Table d'opcodes** en `enum` + `[Opcode]Op_Info` (taille, pop/push, format d'opérande) transcrite de
  `quickjs-opcode.h`. Les opcodes courts suivent `nop` pour reproduire la numérotation exacte de QuickJS ; les
  opcodes temporaires (jamais sérialisés) sont un `enum` séparé (`Temp_Op`).
- **Atomes** : `atoms.odin` porte la table des atomes prédéfinis de `quickjs-atom.h` dans l'ordre exact (donc les
  mêmes valeurs d'indice), détecte les atomes entiers (indices de tableau → encodage tagged-int), et attribue aux
  chaînes nouvelles un indice runtime dans l'ordre de première rencontre — l'ordre qu'utilise `JS_WriteObjectAtoms`.
- **Lexer** : décision `/` vs regexp pilotée par le jeton précédent (`regexp_allowed_after`), au lieu de faire
  porter le contexte au parseur ; plus robuste et moins de bugs.

## Lexer (`lexer.odin`)

ECMAScript 2025 complet : identifiants Unicode avec échappements `\u`/`\u{}`, séparateurs numériques et BigInt,
littéraux de gabarit (y compris fragments head/middle/tail), littéraux regexp (corps + drapeaux, balayage des
classes `[]`), commentaires `//`, `/* */` et Annex B `<!--` / `-->`, hashbang, noms privés `#x`. Les chaînes sont
cuites en Latin-1 ou UTF-16 (la forme que QuickJS sérialise). Les erreurs portent une position ligne/colonne.

## Parseur (`parser.odin`, `parser_expr.odin`)

Descente récursive. Scripts, modules, variantes eval. Grammaire d'instructions complète, ASI, mode strict et
Annex B, prologue de directives (`"use strict"`). Expressions par escalade de précédence (`binary_prec`), avec
`**` associatif à droite. Fonctions (fléchées, async, générateurs, méthodes), classes (champs, statiques, blocs
`static {}`, privés, accesseurs), destructuration, spread, optional chaining, `??`/`??=`, `import`/`export`,
`import()`/`import.meta`, attributs d'import, labels, `with`. Erreurs précoces : `return`/`break`/`continue` hors
contexte, cible d'affectation invalide, `delete` d'identifiant en strict, redéclarations (en partie).

Lookahead borné par instantané du curseur (`save_point`/`restore_point`) : une seule avance de jeton pour
distinguer `let`-déclaration, fonction fléchée, `async function`, label.

## Génération de bytecode (`compile.odin`, `emit.odin`)

`emit.odin` fournit le `Bc_Builder` : émission brute, labels + backpatch, choix des **opcodes courts**
(`push_0..7`, `get_loc0..3`, `get_loc8`, `push_const8`…) et `compute_stack_size` (exploration en largeur fidèle à
QuickJS, suit chute, sauts conditionnels, `catch`, `gosub`). `compile.odin` fait le parcours AST → bytecode.

## Sérialisation (`serialize.odin`)

Reproduit le conteneur `JS_WriteObject2` + `JS_WriteObjectAtoms` :

```
[BC_VERSION u8=28] [checksum u32] [atom_count leb128] [atomes…] [objet…]
```

- LEB128 non signé et zigzag (`put_leb128`, `put_sleb128`), u16/u32/u64 little-endian.
- `JS_WriteFunctionTag` : drapeaux empaquetés (`has_prototype`, `func_kind`, …), compteurs, table des `vardefs`
  (nom, scope_level, scope_next+1, drapeaux, var_ref_idx), table `closure_var`, pool de constantes récursif,
  bytecode (les opérandes d'atome sont réécrites en indices sérialisés comme dans `JS_WriteFunctionBytecode`),
  section debug (pc2line, source stripée).
- `bc_csum` recalculé sur tout après les 5 premiers octets, patché à l'offset 1.
- `first_atom = JS_ATOM_END` : les atomes prédéfinis s'écrivent inline par valeur, seuls les atomes runtime
  passent par la table d'indices.

## Juges (`judge/`)

Outil `judge` (hôte) :

- `parse` / `parse-module` : parse chaque fichier, PASS/FAIL + message au format QuickJS.
- `compile` : parse + compile + sérialise, affiche la taille et un préfixe hexa.
- `dump` : flux `JS_WriteObject` complet en hexa, pour un **diff octet pour octet** avec le moteur C.
- `speed` : MB/s de parse (opt-in, jamais en CI).
- `fuzz` : sweep de mutations, ne doit ni planter ni boucler.

Le différentiel de bytecode se fait contre un `JS_WriteObject` du QuickJS C : comparer `judge dump f.js` avec le
flux produit par le moteur C sur le même fichier (compilé en mode `COMPILE_ONLY`, écrit avec `JS_WRITE_OBJ_BYTECODE`).

## Divergences voulues / en cours

- **Numérotation et format** : identiques à QuickJS (contrat avec E2).
- **Valeur de complétion d'un script** : on termine sur `return_undef` ; QuickJS peut porter la valeur de la
  dernière expression. À affiner pour la parité octet sur les scripts eval.
- **Passe peephole de `resolve_labels`** : on fait le backpatch et le choix d'opcodes courts aux points
  d'émission ; les règles peephole complètes de QuickJS (fusion `get_loc`/`put_loc`, `dup`+`drop`, etc.) restent à
  ajouter pour la parité octet fine.
- **Lowering en cours** (le parseur les accepte, l'émission émet un diagnostic ou un repli) : classes, for-in/of,
  try/catch, switch, with, générateurs/async (flux de contrôle), destructuration, templates balisés, super,
  import.meta, spread d'appel/tableau. Le flux reste bien formé.

## Ce que E2 doit savoir

- Les octets produits suivent `BC_VERSION 28`. Le point d'entrée pour obtenir le flux : `compile_script(src,
  alloc)` puis `write_object_of(res, alloc)` ; `parse_program` pour un AST seul.
- La table des atomes prédéfinis (`PREDEFINED_ATOMS`) doit rester synchronisée avec celle de E2 : même ordre,
  mêmes chaînes (sinon les indices d'atomes divergent).
