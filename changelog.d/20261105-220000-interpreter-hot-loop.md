type: Changed

**Scripts run faster in the interpreter**: `this`, `===` and `==` of strings and of mixed values, bitwise operators on doubles (a hash in JavaScript), a string's `length` and methods, an array's methods, `typeof`, object literals, closures and `+` of strings no longer leave the interpreter's fast loop; `o["name"]` is compiled as `o.name`, `return f()` as a plain call. npr.org's DOMContentLoaded comes more than twice as early.
