type: Added

**PointerEvent.getCoalescedEvents() and Linux parity**: implemented `PointerEvent.prototype.getCoalescedEvents()` and `PointerEventInit.coalescedEvents` (retaining sub-frame pointer move samples for drawing apps), wired the toolkit colour picker popover for `<input type="color">` off Windows, and added the Linux loopback TCP listener for `--remote-debugging-port` (CDP / WebDriver BiDi).
