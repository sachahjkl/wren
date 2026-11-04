type: Fixed

**Script elements moved or nested**: a script moved into a frame's document while it loads no longer runs (it still holds back the scripts after it and the load event of its first document), and an SVG `<script>` written inside another one runs first, the outer one getting its whole text.
