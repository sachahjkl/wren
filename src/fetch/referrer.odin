package fetch

import "core:strings"
import "wb:url"

// Parses a Referrer-Policy header / meta value: a comma separated list; the last recognised token wins.
parse_referrer_policy :: proc(value: string) -> Referrer_Policy {
	result := Referrer_Policy.Default
	for tok in strings.split(value, ",", context.temp_allocator) {
		t := strings.trim_space(tok)
		switch {
		case strings.equal_fold(t, "no-referrer"):                       result = .No_Referrer
		case strings.equal_fold(t, "no-referrer-when-downgrade"):        result = .No_Referrer_When_Downgrade
		case strings.equal_fold(t, "same-origin"):                       result = .Same_Origin
		case strings.equal_fold(t, "origin"):                            result = .Origin
		case strings.equal_fold(t, "strict-origin"):                     result = .Strict_Origin
		case strings.equal_fold(t, "origin-when-cross-origin"):          result = .Origin_When_Cross_Origin
		case strings.equal_fold(t, "strict-origin-when-cross-origin"):   result = .Strict_Origin_When_Cross_Origin
		case strings.equal_fold(t, "unsafe-url"):                        result = .Unsafe_Url
		}
	}
	return result
}

// The value of the Referer header for a request from `source` (the document URL) to `target`, or ok = false for none.
// Referrer Policy §8.3, "determine request's referrer".
determine_referrer :: proc(source, target: url.URL, policy: Referrer_Policy, max_length: int, allocator := context.allocator) -> (value: string, ok: bool) {
	if source.scheme != "http" && source.scheme != "https" { return "", false }   // file:, about:, data:, opaque origins
	if source.host_kind == .None { return "", false }

	// the referrer URL: no credentials, no fragment
	stripped := strings.builder_make(context.temp_allocator)
	strings.write_string(&stripped, source.scheme)
	strings.write_string(&stripped, "://")
	strings.write_string(&stripped, source.host)
	if source.port >= 0 { strings.write_byte(&stripped, ':'); strings.write_int(&stripped, source.port) }
	strings.write_string(&stripped, source.path)
	if source.has_query { strings.write_byte(&stripped, '?'); strings.write_string(&stripped, source.query) }
	full := strings.to_string(stripped)

	origin_only := strings.concatenate({source.scheme, "://", source.host, source.port >= 0 ? ":" : "",
		source.port >= 0 ? port_to_string(source.port) : "", "/"}, context.temp_allocator)
	if len(full) > max_length { full = origin_only }

	src_origin := url.origin_of(source, context.temp_allocator)
	dst_origin := url.origin_of(target, context.temp_allocator)
	same := url.same_origin(src_origin, dst_origin)
	downgrade := url.is_potentially_trustworthy(source) && !url.is_potentially_trustworthy(target)

	pick :: proc(s: string, allocator := context.allocator) -> (string, bool) { return strings.clone(s, allocator), true }

	eff := policy
	if eff == .Default { eff = .Strict_Origin_When_Cross_Origin }
	switch eff {
	case .No_Referrer, .Default: return "", false
	case .Unsafe_Url:            return pick(full, allocator)
	case .Origin:                return pick(origin_only, allocator)
	case .No_Referrer_When_Downgrade:
		if downgrade { return "", false }
		return pick(full, allocator)
	case .Same_Origin:
		if !same { return "", false }
		return pick(full, allocator)
	case .Strict_Origin:
		if downgrade { return "", false }
		return pick(origin_only, allocator)
	case .Origin_When_Cross_Origin:
		return pick(same ? full : origin_only, allocator)
	case .Strict_Origin_When_Cross_Origin:
		if same { return pick(full, allocator) }
		if downgrade { return "", false }
		return pick(origin_only, allocator)
	}
	return "", false
}

@(private)
port_to_string :: proc(p: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_int(&sb, p)
	return strings.to_string(sb)
}
