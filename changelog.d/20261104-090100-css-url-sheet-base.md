type: Fixed

**A computed `url()` is absolute, against the sheet that wrote it**: `getComputedStyle(el).backgroundImage` gives `url("https://...")` resolved against the base of the stylesheet the value came from (a linked or imported sheet, a constructed sheet's `baseURL`, a CSS module's URL), the document's for a `style` attribute, as other browsers do. A CSS module fetched through a redirect resolves its URLs, its images' included, against where the redirect led.
