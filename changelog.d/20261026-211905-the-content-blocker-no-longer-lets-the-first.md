type: Fixed

**The content blocker no longer lets the first page of a session through unfiltered** (`fetch.hold_requests`, `engine_build.odin`): until the compiled index of the lists is loaded (no valid cache in the profile: first start, a throwaway profile, a new index format) only the small base list was in force, so a YouTube watch page opened at once kept `ytInitialPlayerResponse.adPlacements`, `adSlots` and the ad entries (the next page, with the index there, was clean). The requests to the network now wait for the compile job (at most 20 s), then go through the lists.
