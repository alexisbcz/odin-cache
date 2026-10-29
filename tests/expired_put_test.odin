package cache_tests

import cache ".."
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

// A put over an expired entry drops the old pair as expired and inserts a fresh one.
@(test)
test_lru_put_over_expired_key_reports_expired :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2, fake_options(&clock))
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	clock.now = time.Minute
	_ = cache.lru_put(&c, 1, 11)

	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect_value(t, events[0], Event{1, 10, .Expired})
	}
	s := cache.lru_stats(&c)
	testing.expect_value(t, s.expirations, 1)
	testing.expect_value(t, s.inserts, 2)
	testing.expect_value(t, s.updates, 0)
	v, ok := cache.lru_get(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, v, 11)
}

@(test)
test_lfu_put_over_expired_key_resets_frequency :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2, fake_options(&clock))
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put_ttl(&c, 1, 10, time.Second)
	for _ in 0 ..< 10 {
		_, _ = cache.lfu_get(&c, 1)
	}
	clock.now = time.Minute
	_ = cache.lfu_put(&c, 1, 11)

	freq, ok := cache.lfu_frequency(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, freq, 1)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect_value(t, events[0], Event{1, 10, .Expired})
	}
	s := cache.lfu_stats(&c)
	testing.expect_value(t, s.expirations, 1)
	testing.expect_value(t, s.inserts, 2)
	testing.expect_value(t, s.updates, 0)

	// The fresh entry must lose to an entry that was really used more.
	_ = cache.lfu_put(&c, 2, 20)
	_, _ = cache.lfu_get(&c, 2)
	_ = cache.lfu_put(&c, 3, 30)
	testing.expect(t, !cache.lfu_contains(&c, 1))
	testing.expect(t, cache.lfu_contains(&c, 2))
}

// Owned keys and values put over expired entries must not leak or double free.
@(test)
test_owned_strings_put_over_expired_do_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	clock: Fake_Clock
	lru: cache.LRU(string, string)
	lfu: cache.LFU(string, string)
	_ = cache.lru_init(&lru, 4, fake_options(&clock, time.Second), allocator)
	_ = cache.lfu_init(&lfu, 4, fake_options(&clock, time.Second), allocator)
	cache.lru_set_evict_callback(&lru, free_owned, &allocator)
	cache.lfu_set_evict_callback(&lfu, free_owned, &allocator)

	for i in 0 ..< 200 {
		clock.now += 300 * time.Millisecond
		k := i % 6
		_ = cache.lru_put(&lru, fmt.aprintf("k%d", k, allocator = allocator), fmt.aprintf("v%d", i, allocator = allocator))
		_ = cache.lfu_put(&lfu, fmt.aprintf("k%d", k, allocator = allocator), fmt.aprintf("v%d", i, allocator = allocator))
	}
	testing.expect(t, cache.lru_stats(&lru).expirations > 0)
	testing.expect(t, cache.lfu_stats(&lfu).expirations > 0)
	cache.lru_destroy(&lru)
	cache.lfu_destroy(&lfu)
	expect_no_leaks(t, &track)
}
