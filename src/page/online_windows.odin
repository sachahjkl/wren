package page

foreign import sensapi "system:Sensapi.lib"

@(default_calling_convention = "system", private = "file")
foreign sensapi {
	IsNetworkAlive :: proc(flags: ^u32) -> i32 ---
}

// navigator.onLine: does the system have a network connection (LAN or WAN)?
network_alive :: proc() -> bool {
	flags: u32
	return IsNetworkAlive(&flags) != 0
}
