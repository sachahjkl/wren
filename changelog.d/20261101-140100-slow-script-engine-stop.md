type: Fixed

**A slow script no longer costs the page its scripts on a busy machine**: a loop of `document.write`, or of any call into the browser that takes long, saw the slow-script stop too late and the page's JavaScript was stopped for good ("scripts no longer run on this page"); it now ends the script alone, and the hard stop waits until the script really had the time to end.
