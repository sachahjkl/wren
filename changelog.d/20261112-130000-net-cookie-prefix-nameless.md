type: Security

**A nameless cookie can no longer pose as a `__Host-` or `__Secure-` cookie**: `Set-Cookie: =__Host-sid=evil` (or `__Host-sid` alone) is refused. Such a cookie reached the server as `__Host-sid`, although none of the prefix's rules had been checked.
