type: Changed

**`tools\test_all.ps1 -CI`**: sets the `CI` variable when it is not set, so the checks that skip themselves on the CI (the receive time-out of `nettest`, which fails on a loaded machine) also skip in a local `-CI` run.
