package cache_tests

import cache ".."
import "core:testing"
import "core:time"

// A shrinking resize reports entries whose TTL already ran out as expired.
@(test)
test_lru_resize_shrink_reports_expired_victims :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 3, fake_options(&clock))
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	_ = cache.lru_put(&c, 2, 20)
	_ = cache.lru_put(&c, 3, 30)
	clock.now = time.Minute
	testing.expect_value(t, cache.lru_resize(&c, 1), nil)

	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0], Event{1, 10, .Expired})
		testing.expect_value(t, events[1], Event{2, 20, .Capacity})
	}
	s := cache.lru_stats(&c)
	testing.expect_value(t, s.expirations, 1)
	testing.expect_value(t, s.evictions, 1)
}

@(test)
test_lfu_resize_shrink_reports_expired_victims :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 3, fake_options(&clock))
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put_ttl(&c, 1, 10, time.Second)
	_ = cache.lfu_put(&c, 2, 20)
	_ = cache.lfu_put(&c, 3, 30)
	_, _ = cache.lfu_get(&c, 3)
	clock.now = time.Minute
	testing.expect_value(t, cache.lfu_resize(&c, 1), nil)

	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0], Event{1, 10, .Expired})
		testing.expect_value(t, events[1], Event{2, 20, .Capacity})
	}
	s := cache.lfu_stats(&c)
	testing.expect_value(t, s.expirations, 1)
	testing.expect_value(t, s.evictions, 1)
}
