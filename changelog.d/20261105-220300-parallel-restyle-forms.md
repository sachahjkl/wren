type: Fixed

**A crash in a large partial restyle with radio buttons**: the style threads built the forms model's lists at once, as a full pass does not: the partial pass now settles them first.
