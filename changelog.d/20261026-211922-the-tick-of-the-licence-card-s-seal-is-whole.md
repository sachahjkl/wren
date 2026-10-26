type: Fixed

**The tick of the licence card's seal is whole** (`about_card.odin`): its lower end was cut off (a bordered 9 x 18 px box turned 45 degrees inside a `drop-shadow` filter, in a 13 x 22 px wrapper). It is now an inline SVG path with round caps and joins (three points, 4 px wide), in a wrapper the size of the seal, in the CSS fallback and as the geometry the seal's raised tick is drawn from.
