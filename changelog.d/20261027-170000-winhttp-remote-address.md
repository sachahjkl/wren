type: Fixed

**The Network panel shows the whole remote address on the WinHTTP stack** (`net.remember_address`): it was cut to "127.0:port" (WinHTTP gives a wide address's length in characters, not bytes).
