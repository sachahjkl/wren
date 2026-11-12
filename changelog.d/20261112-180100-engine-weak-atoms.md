type: Fixed

**Property keys are freed**: a page that makes many keys at run time (`obj[id]`, `id in obj`, `JSON.parse` of varied data) no longer keeps every key string for the life of the page; the keys nothing uses are freed at the next collection.
