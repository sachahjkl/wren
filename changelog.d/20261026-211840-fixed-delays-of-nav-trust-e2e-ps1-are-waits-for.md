type: Changed

**Fixed delays of `nav_trust_e2e.ps1` are waits for a condition, `remote_page_e2e.ps1` starts two Wren instead of three, and `test_all.ps1` prints how many Wren processes the scripts started** (`Note-WrenStart` in `tools\wrenctl.ps1`; seven `Start-Sleep` of 600 to 800 ms become `wren ctl wait idle`: 12.0 s to 5.9 s here); `CONTRIBUTING.md` says why one shared Wren and `reset` come before a start per scenario.
