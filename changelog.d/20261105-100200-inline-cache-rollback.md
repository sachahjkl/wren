type: Fixed

**A read of freed memory in the style attribute cache** (`Styled.inline_rules`): a partial restyle that changed nothing gave back the memory of the entry the cache had just kept for a new `style` attribute, whose key and rule then lived in memory the next allocation took (npr.org: a crash at the load with freed memory poisoned, wrong styles or a crash otherwise).
