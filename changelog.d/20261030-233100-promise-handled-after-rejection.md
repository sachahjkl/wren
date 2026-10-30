type: Fixed

**A stream's reader released while reading no longer reports an unhandled rejection** ("Releasing Default reader"), which stopped a worker in DuckDB's shell and failed `pipeTo` tests: a promise marked as handled after its rejection now tells the rejection tracker.
