type: Changed

**Stylesheets that go, change or wake up no longer restyle the document**: a `<style>` or `<link>` that leaves, a `<style>` whose text is rewritten, an `@import` that arrives after its sheet, a `<link media=print>` switched on when loaded and an element the embedder hides restyle what they reach, without reading every sheet again.
