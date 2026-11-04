type: Fixed

**Scripts that did not start can start later**: a `<script>` the parser met empty or with another `type` runs when a script gives it text, removes its `type` or inserts it again (and is then async), the children of a fragment are all inserted before a script among them runs, SVG `<script href>` loads its file, and `moveBefore` runs no script.
