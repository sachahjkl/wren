type: Changed

**Text measured once per layout**: a paragraph laid out again in the same layout (a flex item, a box sized by its content, `text-wrap: balance`) reuses the widths of its words instead of measuring them again, and a form control measures its labels once. Text that breaks anywhere (`overflow-wrap`, `word-break`, `text-overflow: ellipsis`) can be measured in one call to the shell.
