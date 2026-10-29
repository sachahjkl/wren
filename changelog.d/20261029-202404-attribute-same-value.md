type: Fixed

**setAttribute with the value the attribute has**: observers and attributeChangedCallback still see the write, as the DOM says, but the document no longer changes: no new version, no restyle, no layout (classList.add of a class already there, a script that sets a data attribute at every scroll event).
