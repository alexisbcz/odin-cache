// Package cache_tests holds the unit tests for cache. Run them with `odin test tests`.
package cache_tests

import cache ".."
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

// Fake_Clock lets tests move time forward without sleeping.
Fake_Clock :: struct {
	now: time.Duration,
}

fake_now :: proc(data: rawptr) -> time.Duration {
	return (^Fake_Clock)(data).now
}

fake_options :: proc(clock: ^Fake_Clock, default_ttl := cache.NO_EXPIRY) -> cache.Options {
	return {default_ttl = default_ttl, clock = {procedure = fake_now, data = clock}}
}

// Event records one call of the eviction callback.
Event :: struct {
	key:    int,
	value:  int,
	reason: cache.Evict_Reason,
}

record_event :: proc(key: int, value: int, reason: cache.Evict_Reason, user_data: rawptr) {
	events := (^[dynamic]Event)(user_data)
	append(events, Event{key, value, reason})
}

// free_owned frees string keys and values cloned by the test.
free_owned :: proc(key: string, value: string, reason: cache.Evict_Reason, user_data: rawptr) {
	allocator := (^mem.Allocator)(user_data)^
	delete(key, allocator)
	delete(value, allocator)
}

// expect_no_leaks fails the test if `track` saw any leak or bad free.
expect_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations leaked", len(track.allocation_map), loc = loc)
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array), loc = loc)
}

@(test)
test_hit_ratio_without_lookups_is_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, cache.hit_ratio({}), 0)
}

@(test)
test_hit_ratio_divides_hits_by_lookups :: proc(t: ^testing.T) {
	testing.expect_value(t, cache.hit_ratio({hits = 3, misses = 1}), 0.75)
}

@(test)
test_errors_print_as_messages :: proc(t: ^testing.T) {
	err: cache.Error = cache.Usage_Error.Invalid_TTL
	testing.expect_value(t, fmt.tprint(err), "Invalid_TTL")
	testing.expect_value(t, fmt.tprint(cache.Evict_Reason.Capacity), "Capacity")
}

@(test)
test_system_clock_expires_entries :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_init(&c, 2, cache.Options{default_ttl = 2 * time.Millisecond}), nil)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 1)
	_ = cache.lru_put_ttl(&c, 2, 2, time.Hour)
	time.sleep(10 * time.Millisecond)
	testing.expect(t, !cache.lru_contains(&c, 1))
	testing.expect(t, cache.lru_contains(&c, 2))
}
