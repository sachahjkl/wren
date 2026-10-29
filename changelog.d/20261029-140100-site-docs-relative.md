type: Fixed

**Documentation du site : liens relatifs** : les pages de `/wren/docs/` utilisaient des liens à la racine (`/style.css`), qui sortaient du site publié sous `/wren/` : pas de style, logo cassé. Le générateur écrit maintenant des liens relatifs à la racine du site, y compris pour la recherche. La page Changelog du site est générée depuis `docs/releases` et `CHANGELOG.md`, et les quatre images de la page d'accueil (une fenêtre à quatre onglets, chacun devant à son tour) sont refaites par `tools\hero_shots.ps1`.
