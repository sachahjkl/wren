Type: Added

**Form-associated custom elements** (`src/forms/custom.odin`, `src/page/js_custom_elements.odin`): an autonomous custom element whose class says `static formAssociated = true` is a listed, labelable, submittable and resettable control of its form, disabled by its attribute or a fieldset; `ElementInternals` gives its form members (`setFormValue`, `setValidity`, `form`, `labels`, validity), and its `formAssociatedCallback`, `formDisabledCallback` and `formResetCallback` run.
