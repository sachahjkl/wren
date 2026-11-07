type: Fixed

**The release build builds again** (`wrentool build release`: two imports used only outside a release failed `-vet` since the replay bench), and **`wrentool build bench`** builds the release's code on the development channel, so that the replay bench measures what is shipped with its test world.
