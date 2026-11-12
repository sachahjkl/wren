type: Fixed

**Long scripts no longer pile up memory**: the temporary memory of each call a script makes into the browser (text read, HTML serialized, lists of nodes) is given back when the call returns, not at the end of the task.
