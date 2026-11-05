type: Fixed

**A read of freed memory when the browser closed with several tabs**: the tabs were freed one by one while still in their strips, and a request that ended with a later tab looked them up (`net_observe`, `tab_by_id`).
