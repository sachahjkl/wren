type: Fixed

**Live lists (childNodes, children, getElementsByClassName) stay valid across unrelated changes.** A change elsewhere in the document no longer makes the next read walk the whole list again.
