type: Fixed

`getComputedStyle` answers for shorthands (`border-radius`, `border`, `border-*`, `outline`, `inset`, `gap`, `flex`, `flex-flow`, `text-decoration`, `background`, `font`) and `mask-image` instead of an empty string, and `margin` and `padding` in their shortest form: reddit.com's scripts threw on the NaN they made of it.
