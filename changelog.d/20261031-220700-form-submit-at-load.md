type: Fixed

A form submitted while the page loads (a login's automatic POST, reddit's check page) navigates: it reached the browser before the shell had attached itself to the page, and was dropped with `form submission ignored: no navigator`.
