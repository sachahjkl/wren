type: Fixed

**Stylesheets of a page resolve their URLs against its base URL**: the `<base href>` of the document, not its address, for `<style>` sheets and constructed ones (`@font-face` sources, `url()` images, `@import`), `<link rel=stylesheet>` addresses and inline style images. A copy of a Google page saved with `<base href="https://www.google.com/">` asked Google Sans at `file://fonts.gstatic.com`.
