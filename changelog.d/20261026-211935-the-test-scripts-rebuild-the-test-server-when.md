type: Fixed

**The test scripts rebuild the test server when its sources are newer** (`tools/test_env.ps1` `Ensure-WrenTestServer`, one builder at a time under a named mutex): `Start-WrenTestServer` only built `build\testserver.exe` when it was missing, so a worktree whose `build\` was old kept a server without the routes of newer tests (a 404 on `/video/f/` made `remote_e2e`'s video checks time out on a machine, with nothing wrong in the browser).
