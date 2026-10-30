# Downloads

A navigation whose answer is not a page to show (an attachment, an archive, an installer, a PDF, media…) becomes a
download. The same connection goes on as the download: nothing is asked twice, so a POST or a one-time link works. The tab
keeps the page it showed. The body is written to a temporary file next to the destination (`name.ext.wrenpart`), chunk by
chunk on the background threads, and moved into place when it is complete.

## The button and its drop-down

Once a download has run in the session, a button with an arrow into a tray joins the toolbar, before the shield
(`browser.download.button`: `auto`, `always` or `never`). While something downloads, a ring turns around the arrow and
fills as the files arrive (a comet runs instead while a size is not announced); a dot says that something ended that has
not been looked at. A download that begins opens the drop-down under the button by itself.

The drop-down lists the six latest downloads. A running one shows its name, how much of how much, the speed and the time
left, and a progress bar: a gradient that eases toward the real figure, a gloss on its upper half and a light band
travelling over it. The cross cancels it. A finished one opens its file when clicked; its folder icon shows it in the file
manager. **Show all** opens the page; **Open the folder** opens the download folder.

## about:downloads (Ctrl+J)

The page lists every download, the running ones first, the others by day, newest first. A search box filters by name or
address. A running row has a **Cancel** button and its percentage; a finished one has **Open** and **Show in folder**, and
a menu (**⋯**, or a right click on the row):

- **Open**, **Show in folder**;
- **Copy download link**;
- **Download again**: the address is opened again in a new tab;
- **Delete the file**: the file is deleted (it does not go to the recycle bin); the row stays and says so;
- **Remove from the list**: the row goes, the file stays.

A failed or cancelled download offers **Try again**. **Clear the list** takes every finished download off the list; the
files stay where they are.

The list survives a restart: the finished downloads are written to `downloads.txt` in the profile (state, times, size,
address, path and name, one line each), up to `browser.download.list_max` of them. A file moved or deleted since shows
"Deleted or moved". Nothing running is written.

## Preferences

| Preference | Default | |
|---|---|---|
| `browser.download.ask` | `true` | Ask where to save each download (the Save dialog of Windows). |
| `browser.download.directory` | empty | The folder downloads go to; empty is the Downloads folder of Windows. |
| `browser.download.button` | `auto` | When the toolbar's button shows. |
| `browser.download.list_max` | 200 | Finished downloads the list keeps, across restarts. |
| `browser.download.max_bytes` | 0 | Largest download accepted; 0 is no limit. |
| `browser.download.flush_bytes` | 1 MB | Bytes gathered before a chunk goes to the disk. |
| `browser.download.max_buffered_bytes` | 64 MB | Most bytes kept in memory while the disk is busy. |
| `browser.download.temp_suffix` | `.wrenpart` | Suffix of the temporary file. |
