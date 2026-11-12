type: Fixed

**MutationObserver stays fast when many nodes are removed.** Removing many children of an observed node, or exceeding `javascript.dom.max_mutation_records`, made each later mutation slower.
