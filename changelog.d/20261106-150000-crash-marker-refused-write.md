type: Fixed

**A crash after a stable restore could lose the tabs**: when a virus scanner or anything else had `running.txt` open at the moment the run became stable, the write was refused and never tried again, so the next crash was taken for the second in a row. The marker and the crash snapshot are now written again until they go through.
