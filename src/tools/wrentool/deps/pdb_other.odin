#+build !windows
package deps

// (a PE program's PDB: nothing to read on another system; Linux reports go through addr2line)
Pdb_Session :: struct {}
pdb_open :: proc(exe: string, base: u64, size: u64) -> (s: Pdb_Session, why: string) { return s, "no PDB on this system" }
pdb_close :: proc(s: ^Pdb_Session) {}
pdb_name :: proc(s: ^Pdb_Session, address: u64) -> string { return "" }
