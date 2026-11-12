type: Changed

**Faster pages built of nested flex containers**: a flex item measured at its auto height and then laid out at its final height keeps both results, so each level of nesting is laid out a few times instead of twice as often as the level around it. Pages built of deep stacks of flex columns and rows lay out and resize much faster.
