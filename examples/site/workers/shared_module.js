// A module shared worker of src/tools/e2e/workers.odin: a static import, and what it computes said to whoever connects.
import { twice } from "./lib/math.js";

self.onconnect = (e) => e.ports[0].postMessage("module shared " + self.name + " " + twice(21));
