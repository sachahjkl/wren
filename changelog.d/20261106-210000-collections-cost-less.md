type: Changed

**Garbage collection stops a page for far less time**: a collection frees its dead objects a little at a time while the script goes on, walks an array instead of chasing pointers, and comes less often on large heaps, so during a heavy load it takes about 40 % less of the page's thread and its longest pause falls from about 100 ms to under 40 ms on theverge.com, at the price of up to 7 % more private memory on such pages, a quarter more of the page's own at most.
