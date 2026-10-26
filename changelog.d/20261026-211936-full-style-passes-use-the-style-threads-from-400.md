type: Fixed

**Full style passes use the style threads from 400 nodes** (`page.threads.style_min_nodes`, was 4 000): a page of 1 800 elements that uses many custom properties (Tailwind) took 90 ms on one thread and takes 20 ms shared out; `build_style` also keeps its tables of custom properties between elements and puts the touched properties in order from a bit set instead of sorting them.
