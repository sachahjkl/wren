type: Added

**`text-wrap: balance`** : un paragraphe de six lignes au plus garde son nombre de lignes, mais ses lignes se coupent à la largeur la plus étroite qui le permet (recherche par dichotomie sur la largeur de coupure) ; l'alignement (`text-align: center`, `end`) reste calculé sur la largeur entière, comme Blink. Les titres `text-balance` de Bootstrap 6, Tailwind et d'autres s'affichent comme dans Edge. Ignoré quand le paragraphe contient un flottant, un élément en ligne atomique, un `<br>` ou un bloc.
