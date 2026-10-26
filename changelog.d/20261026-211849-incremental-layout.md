type: Fixed

**Incremental layout** could crash (`has_block_child`, a dead box rebuilt) when an attribute that rebuilds an element's box changed inside a box the same pass made again alone (found on YouTube's home page): the boxes a plan took with it are no longer rebuilt as roots.
