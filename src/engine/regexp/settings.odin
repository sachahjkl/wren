#+build windows, linux, darwin
package regexp

// Preferences for the regexp engine. Only the hosted targets build this file; the freestanding_wasm32 build of
// the engine never pulls in the preference registry (it has no OS), and the caller passes Exec_Limits directly.
// The limits guard against pathological patterns: an attacker-controlled page cannot make an exec run or recurse
// without bound, because the VM charges a step per dispatch and caps its backtrack stack.

import "wb:config"

// What the preferences of the limits may be set to.
LIMIT_PREF_MIN :: 1000
MAX_STEPS_PREF_MAX :: 1 << 40
MAX_STACK_PREF_MAX :: 1 << 32

PREFS := [?]config.Def{
	{name = "regexp.exec.max_steps", kind = .Int, default = {i = DEFAULT_MAX_STEPS}, bounded = true,
		min = LIMIT_PREF_MIN, max = MAX_STEPS_PREF_MAX,
		description = "Largest number of bytecode steps one regexp match may take before it fails with a timeout. Guards against catastrophic backtracking from a hostile pattern or input. The matcher reports the limit was hit rather than hanging."},
	{name = "regexp.exec.max_stack", kind = .Int, default = {i = DEFAULT_MAX_STACK}, bounded = true,
		min = LIMIT_PREF_MIN, max = MAX_STACK_PREF_MAX,
		description = "Largest backtrack stack (saved choice points) one regexp match may hold. The interpreter uses an explicit stack, not native recursion, so this caps memory and depth without risking a C-stack overflow."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

// Read the exec limits from the preference registry into the plain struct the matcher takes.
limits_from_prefs :: proc(p: ^config.Prefs) -> Exec_Limits {
	return Exec_Limits{
		max_steps = int(config.int_of(p, "regexp.exec.max_steps")),
		max_stack = int(config.int_of(p, "regexp.exec.max_stack")),
	}
}
