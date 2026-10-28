package base

// Generational handles now live in the toolkit's `arena` package (toolkit:arena); base keeps the historic names as
// aliases so callers do not change. See toolkit:arena for the whole picture (a Handle can never dangle: removing an
// object bumps the slot's generation, so an old copy fails to resolve instead of reaching whatever reused the slot).

import "../../ext/gui_toolkit/arena"

Handle :: arena.Handle
NIL_HANDLE :: arena.NIL_HANDLE

handle_index :: arena.handle_index
handle_gen :: arena.handle_gen
handle_make :: arena.handle_make

POOL_CHUNK_SHIFT :: arena.POOL_CHUNK_SHIFT
POOL_CHUNK_SIZE :: arena.POOL_CHUNK_SIZE
POOL_CHUNK_MASK :: arena.POOL_CHUNK_MASK

Slot :: arena.Slot
Pool :: arena.Pool

pool_insert :: arena.pool_insert
pool_get :: arena.pool_get
pool_valid :: arena.pool_valid
pool_remove :: arena.pool_remove
pool_handle_at :: arena.pool_handle_at
pool_next :: arena.pool_next
pool_destroy :: arena.pool_destroy
