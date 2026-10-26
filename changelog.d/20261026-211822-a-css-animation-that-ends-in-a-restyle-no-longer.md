type: Changed

A CSS animation that ends in a restyle no longer reads freed memory: the effective style of the last frame holds strings and slices of the animation's arena (a value made through `var()` of an animated custom property), which the transition check compared after the arena was freed; it is freed at the end of the element's update now.
