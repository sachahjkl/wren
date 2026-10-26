type: Fixed

**`build.bat` (development build) takes 25 s again instead of never finishing** (the CI's build steps ran into their 90-minute limit since the several-windows merge): `window_open` and the developer tools' window put `render.surface_create`'s result straight into their record; a local `render.Surface` (its 256-frame present ring) was split by LLVM into thousands of scalars whose debug fragments kept the `-o:speed -debug` code generation of one module going for over an hour. The CI's build steps now fail after 20 minutes and print their duration.
