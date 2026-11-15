type: Changed

**The install's command line is every program's**: `wren --install` installs this copy as Setup's Install button does, `wren --uninstall [--purge]` removes the installed copy (`--purge` also deletes the profile), `wren --status` says the install's state (exit code 0 installed, 2 to repair, 1 not installed), and `wren --setup` opens the Setup dialog. `--desktop-integration=install|remove|status|uninstall` is gone: to take away the integration and keep the program, untick the box in about:config or use Setup. `wren.com` waits for `--install`, `--uninstall` and `--status`.
