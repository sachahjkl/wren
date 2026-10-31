type: Fixed

An element removed from a page with a shadow root and rules on form controls (`:valid`, `:checked`...) no longer hangs the browser while it takes all the memory: a walk of the document went from a shadow root to its host and back for ever (reddit.com, 22 GB in five minutes).
