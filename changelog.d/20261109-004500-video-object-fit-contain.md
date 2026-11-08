type: Fixed

**A video keeps its shape in its box**: the user agent's style has `video { object-fit: contain; }` (HTML Standard, rendering), so a frame of another shape than its box is drawn whole with bars, as other browsers do, instead of stretched to the box.
