type: Changed

**The browsing history writes only what changed**: each visit and each new title is appended to `history.txt` in the background, instead of the whole history being written again after every visit (up to 10 MB at the 100 000-visit default). The whole file is written again only after a deletion, so that deleted visits leave the disk, or when the file has grown to twice what the history holds. The file is version 2: a history of version 1 is read and written again in the new format at the first save.
