type: Added

**File System Access**: `showOpenFilePicker`, `showSaveFilePicker`, `showDirectoryPicker` (`types`, `excludeAcceptAllOption`, `multiple`, `suggestedName`, `startIn`, `id`, `mode`) with the system's dialogs (toolkit 0.38.1 `platform.open_file_dialog` & co.), a user gesture required (`file_system.user_activation_ms`), `file_system.pickers`; handles on files and folders of the disk, `queryPermission` / `requestPermission` with a prompt of the browser (`file_system.write_permission`: ask, allow, deny); handles survive `structuredClone`, `postMessage` and IndexedDB.
