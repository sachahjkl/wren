type: Fixed

**Two end-to-end tests follow what the last tranche changed** (src/tools/policytest, examples/jsweb/mse.js): with storage partitioned (the default) a third party does not get the cookies it has as a first party, so the policy test checks that, and the unpartitioned case separately; MediaSource.canConstructInDedicatedWorker is true now that a worker may construct one.
