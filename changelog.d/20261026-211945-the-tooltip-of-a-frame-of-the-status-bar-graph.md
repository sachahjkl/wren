type: Fixed

**The tooltip of a frame of the status bar graph keeps its height** (`status_bar.odin`): the Restyle, Layout pass and WebAssembly rows came and went with the frame under the pointer, so on a page whose restyles come in bursts (`examples/site/effects.html`) the tooltip jumped in height as the pointer crossed the bars. The rows are always there, with `--` for a frame that had none.
