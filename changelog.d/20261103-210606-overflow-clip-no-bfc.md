type: Fixed

**`overflow: clip` makes no block formatting context** (CSS Overflow 3), unlike `hidden`: the margins of its children collapse with its own again, and floats are not contained. The empty list items Google's AI mode hides with `block-size: 0; overflow: clip` kept a list item's bottom margin inside the list.
