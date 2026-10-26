package page

import "core:testing"
import "wb:fetch"
import "wb:url"

// Two pages of different sites embedding the same third party (tools/partition_e2e.ps1 has two host names only):
// the third party's storage keys under each, first-party, with storage access, and with partitioning off.
@(test)
storage_keys_partition_a_third_party_per_top_level_site :: proc(t: ^testing.T) {
	origin_of :: proc(s: string) -> url.Origin {
		u, _ := url.parse_absolute(s, context.temp_allocator)
		return url.origin_of(u, context.temp_allocator)
	}
	site_of :: proc(s: string) -> url.Site { return url.site_of(origin_of(s), context.temp_allocator) }
	tracker := origin_of("https://cdn.tracker.net")
	ts := site_of("https://cdn.tracker.net")
	a, b := site_of("https://www.a.com"), site_of("https://shop.b.org")
	under_a := storage_key_of(tracker, ts, a, true, true, .None)
	under_b := storage_key_of(tracker, ts, b, true, true, .None)
	first := storage_key_of(tracker, ts, ts, false, true, .None)
	testing.expect_value(t, under_a, "https://cdn.tracker.net^https://a.com")
	testing.expect_value(t, under_b, "https://cdn.tracker.net^https://b.org")
	testing.expect_value(t, first, "https://cdn.tracker.net")
	// a frame of the same site as its tab, one using its storage access, or partitioning off: the origin
	testing.expect_value(t, storage_key_of(tracker, ts, site_of("https://tracker.net"), true, true, .None), "https://cdn.tracker.net")
	testing.expect_value(t, storage_key_of(tracker, ts, a, true, true, .Active), "https://cdn.tracker.net")
	testing.expect_value(t, storage_key_of(tracker, ts, a, true, true, .Inactive), under_a)
	testing.expect_value(t, storage_key_of(tracker, ts, a, true, false, .None), "https://cdn.tracker.net")
	// schemeful sites: http and https of one domain are two top-level sites
	testing.expect(t, storage_key_of(tracker, ts, site_of("http://www.a.com"), true, true, .None) != under_a)
	// the cookie jar's partitions name the same top-level sites
	testing.expect_value(t, fetch.site_partition_text(a), "https://a.com")
	// "Clear site data" finds a partition by its top-level site's domain, and a key's own site
	testing.expect_value(t, storage_key_top_host(under_b), "b.org")
	testing.expect_value(t, storage_key_host(under_b), "cdn.tracker.net")
	testing.expect_value(t, storage_key_site(under_b), "https://tracker.net")
}
