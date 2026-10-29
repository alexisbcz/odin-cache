package cache_tests

import cache ".."
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:testing"
import "core:time"

Error :: cache.Error
Usage_Error :: cache.Usage_Error

@(test)
test_lru_init_rejects_zero_capacity :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_init(&c, 0), Error(Usage_Error.Invalid_Capacity))
	testing.expect_value(t, cache.lru_cap(&c), 0)
}

@(test)
test_lru_init_rejects_negative_capacity :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_init(&c, -5), Error(Usage_Error.Invalid_Capacity))
}

@(test)
test_lru_init_rejects_capacity_over_max :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_init(&c, cache.MAX_CAPACITY + 1), Error(Usage_Error.Invalid_Capacity))
}

@(test)
test_lru_init_rejects_negative_default_ttl :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	err := cache.lru_init(&c, 4, cache.Options{default_ttl = -time.Second})
	testing.expect_value(t, err, Error(Usage_Error.Invalid_TTL))
}

@(test)
test_lru_init_reports_allocator_failure :: proc(t: ^testing.T) {
	buf: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	c: cache.LRU(int, int)
	err := cache.lru_init(&c, 1000, allocator = mem.arena_allocator(&arena))
	testing.expect_value(t, err, Error(mem.Allocator_Error.Out_Of_Memory))
	testing.expect_value(t, cache.lru_cap(&c), 0)
}

@(test)
test_lru_put_before_init_is_rejected :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_put(&c, 1, 1), Error(Usage_Error.Not_Initialized))
	_, ok := cache.lru_get(&c, 1)
	testing.expect(t, !ok)
}

@(test)
test_lru_destroy_zero_value_is_noop :: proc(t: ^testing.T) {
	c: cache.LRU(string, int)
	cache.lru_destroy(&c)
	testing.expect_value(t, cache.lru_len(&c), 0)
}

@(test)
test_lru_put_then_get_returns_value :: proc(t: ^testing.T) {
	c: cache.LRU(string, int)
	testing.expect_value(t, cache.lru_init(&c, 4), nil)
	defer cache.lru_destroy(&c)

	testing.expect_value(t, cache.lru_put(&c, "a", 1), nil)
	v, ok := cache.lru_get(&c, "a")
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)
	testing.expect_value(t, cache.lru_len(&c), 1)
	testing.expect_value(t, cache.lru_cap(&c), 4)
}

@(test)
test_lru_get_missing_key_is_miss :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	v, ok := cache.lru_get(&c, 7)
	testing.expect(t, !ok)
	testing.expect_value(t, v, 0)
	testing.expect_value(t, cache.lru_stats(&c).misses, 1)
}

@(test)
test_lru_put_existing_key_replaces_value :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 1, 11)
	v, _ := cache.lru_get(&c, 1)
	testing.expect_value(t, v, 11)
	testing.expect_value(t, cache.lru_len(&c), 1)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Replaced})
	testing.expect_value(t, cache.lru_stats(&c).updates, 1)
	testing.expect_value(t, cache.lru_stats(&c).inserts, 1)
}

@(test)
test_lru_evicts_least_recently_used :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	_ = cache.lru_put(&c, 3, 30)

	testing.expect(t, !cache.lru_contains(&c, 1))
	testing.expect(t, cache.lru_contains(&c, 2))
	testing.expect(t, cache.lru_contains(&c, 3))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Capacity})
	testing.expect_value(t, cache.lru_stats(&c).evictions, 1)
}

@(test)
test_lru_get_marks_entry_recently_used :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	_, _ = cache.lru_get(&c, 1)
	_ = cache.lru_put(&c, 3, 30)

	testing.expect(t, cache.lru_contains(&c, 1))
	testing.expect(t, !cache.lru_contains(&c, 2))
}

@(test)
test_lru_put_existing_key_marks_recently_used :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	_ = cache.lru_put(&c, 1, 11)
	_ = cache.lru_put(&c, 3, 30)

	testing.expect(t, cache.lru_contains(&c, 1))
	testing.expect(t, !cache.lru_contains(&c, 2))
}

@(test)
test_lru_peek_does_not_change_recency_or_stats :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	v, ok := cache.lru_peek(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, v, 10)
	_, ok = cache.lru_peek(&c, 9)
	testing.expect(t, !ok)
	_ = cache.lru_put(&c, 3, 30)

	testing.expect(t, !cache.lru_contains(&c, 1))
	s := cache.lru_stats(&c)
	testing.expect_value(t, s.hits, 0)
	testing.expect_value(t, s.misses, 0)
}

@(test)
test_lru_get_ptr_allows_in_place_update :: proc(t: ^testing.T) {
	c: cache.LRU(int, [4]int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, [4]int{1, 2, 3, 4})
	p, ok := cache.lru_get_ptr(&c, 1)
	testing.expect(t, ok)
	p[2] = 99
	v, _ := cache.lru_peek(&c, 1)
	testing.expect_value(t, v, [4]int{1, 2, 99, 4})

	p, ok = cache.lru_get_ptr(&c, 2)
	testing.expect(t, !ok)
	testing.expect(t, p == nil)
}

@(test)
test_lru_remove_runs_callback :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	testing.expect(t, cache.lru_remove(&c, 1))
	testing.expect(t, !cache.lru_remove(&c, 1))
	testing.expect_value(t, cache.lru_len(&c), 0)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Removed})
	testing.expect_value(t, cache.lru_stats(&c).removals, 1)
}

@(test)
test_lru_remove_frees_slot_for_reuse :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	_ = cache.lru_remove(&c, 1)
	_ = cache.lru_put(&c, 3, 30)

	testing.expect(t, cache.lru_contains(&c, 2))
	testing.expect(t, cache.lru_contains(&c, 3))
	testing.expect_value(t, cache.lru_stats(&c).evictions, 0)
}

@(test)
test_lru_take_returns_ownership_without_callback :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	k, v, ok := cache.lru_take(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, k, 1)
	testing.expect_value(t, v, 10)
	testing.expect_value(t, len(events), 0)

	_, _, ok = cache.lru_take(&c, 1)
	testing.expect(t, !ok)
}

@(test)
test_lru_clear_empties_and_stays_usable :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 3)
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	cache.lru_clear(&c)
	testing.expect_value(t, cache.lru_len(&c), 0)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0], Event{1, 10, .Cleared})
	testing.expect_value(t, events[1], Event{2, 20, .Cleared})

	for i in 0 ..< 3 {
		testing.expect_value(t, cache.lru_put(&c, i, i), nil)
	}
	testing.expect_value(t, cache.lru_len(&c), 3)
}

@(test)
test_lru_destroy_runs_callback_for_each_entry :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 3)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put(&c, 2, 20)
	cache.lru_destroy(&c)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, cache.lru_cap(&c), 0)
}

@(test)
test_lru_can_be_reinitialized_after_destroy :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 1)
	_ = cache.lru_put(&c, 1, 1)
	cache.lru_destroy(&c)

	testing.expect_value(t, cache.lru_init(&c, 2), nil)
	defer cache.lru_destroy(&c)
	testing.expect(t, !cache.lru_contains(&c, 1))
	testing.expect_value(t, cache.lru_cap(&c), 2)
}

@(test)
test_lru_capacity_one_keeps_latest :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 1)
	defer cache.lru_destroy(&c)

	for i in 0 ..< 10 {
		_ = cache.lru_put(&c, i, i * 2)
	}
	testing.expect_value(t, cache.lru_len(&c), 1)
	v, ok := cache.lru_get(&c, 9)
	testing.expect(t, ok)
	testing.expect_value(t, v, 18)
	testing.expect_value(t, cache.lru_stats(&c).evictions, 9)
}

@(test)
test_lru_put_ttl_rejects_negative_ttl :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	testing.expect_value(t, cache.lru_put_ttl(&c, 1, 1, -time.Millisecond), Error(Usage_Error.Invalid_TTL))
	testing.expect_value(t, cache.lru_len(&c), 0)
}

@(test)
test_lru_entry_expires_after_ttl :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2, fake_options(&clock))
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	clock.now = time.Second - 1
	_, ok := cache.lru_get(&c, 1)
	testing.expect(t, ok)

	clock.now = time.Second
	_, ok = cache.lru_get(&c, 1)
	testing.expect(t, !ok)
	testing.expect_value(t, cache.lru_len(&c), 0)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Expired})

	s := cache.lru_stats(&c)
	testing.expect_value(t, s.expirations, 1)
	testing.expect_value(t, s.hits, 1)
	testing.expect_value(t, s.misses, 1)
}

@(test)
test_lru_default_ttl_applies_to_put :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2, fake_options(&clock, time.Minute))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 10)
	_ = cache.lru_put_ttl(&c, 2, 20, cache.NO_EXPIRY)
	clock.now = time.Hour
	testing.expect(t, !cache.lru_contains(&c, 1))
	testing.expect(t, cache.lru_contains(&c, 2))
}

@(test)
test_lru_replacing_put_resets_ttl :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2, fake_options(&clock))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	clock.now = 900 * time.Millisecond
	_ = cache.lru_put_ttl(&c, 1, 11, time.Second)
	clock.now = 1500 * time.Millisecond
	v, ok := cache.lru_get(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, v, 11)
}

@(test)
test_lru_huge_ttl_does_not_overflow :: proc(t: ^testing.T) {
	clock := Fake_Clock{now = time.Hour}
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 1, fake_options(&clock))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put_ttl(&c, 1, 1, time.Duration(max(i64)))
	clock.now = time.Duration(max(i64) - 1)
	testing.expect(t, cache.lru_contains(&c, 1))
}

@(test)
test_lru_peek_hides_expired_entry_without_removing :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2, fake_options(&clock))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	clock.now = 2 * time.Second
	_, ok := cache.lru_peek(&c, 1)
	testing.expect(t, !ok)
	testing.expect_value(t, cache.lru_len(&c), 1)
}

@(test)
test_lru_purge_expired_removes_only_expired :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 4, fake_options(&clock))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put_ttl(&c, 1, 1, time.Second)
	_ = cache.lru_put_ttl(&c, 2, 2, 3 * time.Second)
	_ = cache.lru_put_ttl(&c, 3, 3, time.Second)
	_ = cache.lru_put(&c, 4, 4)
	clock.now = 2 * time.Second

	testing.expect_value(t, cache.lru_purge_expired(&c), 2)
	testing.expect_value(t, cache.lru_len(&c), 2)
	testing.expect(t, cache.lru_contains(&c, 2))
	testing.expect(t, cache.lru_contains(&c, 4))
	testing.expect_value(t, cache.lru_stats(&c).expirations, 2)
	testing.expect_value(t, cache.lru_purge_expired(&c), 0)
}

@(test)
test_lru_full_cache_reports_expired_victim :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 1, fake_options(&clock))
	defer cache.lru_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lru_set_evict_callback(&c, record_event, &events)

	_ = cache.lru_put_ttl(&c, 1, 10, time.Second)
	clock.now = time.Minute
	_ = cache.lru_put(&c, 2, 20)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].reason, cache.Evict_Reason.Expired)
	testing.expect_value(t, cache.lru_stats(&c).evictions, 0)
}

@(test)
test_lru_resize_shrink_evicts_oldest :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 4)
	defer cache.lru_destroy(&c)

	for i in 1 ..= 4 {
		_ = cache.lru_put(&c, i, i)
	}
	_, _ = cache.lru_get(&c, 1)
	testing.expect_value(t, cache.lru_resize(&c, 2), nil)
	testing.expect_value(t, cache.lru_cap(&c), 2)
	testing.expect_value(t, cache.lru_len(&c), 2)

	// Order is now 1 (most recent), 4. A new put must evict 4.
	_ = cache.lru_put(&c, 5, 5)
	testing.expect(t, cache.lru_contains(&c, 1))
	testing.expect(t, cache.lru_contains(&c, 5))
	testing.expect(t, !cache.lru_contains(&c, 4))
}

@(test)
test_lru_resize_grow_keeps_entries :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 1)
	_ = cache.lru_put(&c, 2, 2)
	testing.expect_value(t, cache.lru_resize(&c, 4), nil)
	_ = cache.lru_put(&c, 3, 3)
	_ = cache.lru_put(&c, 4, 4)
	testing.expect_value(t, cache.lru_len(&c), 4)
	for i in 1 ..= 4 {
		v, ok := cache.lru_get(&c, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, i)
	}
	testing.expect_value(t, cache.lru_stats(&c).evictions, 0)
}

@(test)
test_lru_resize_rejects_bad_arguments :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	testing.expect_value(t, cache.lru_resize(&c, 4), Error(Usage_Error.Not_Initialized))
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)
	testing.expect_value(t, cache.lru_resize(&c, 0), Error(Usage_Error.Invalid_Capacity))
	testing.expect_value(t, cache.lru_resize(&c, 2), nil)
}

@(test)
test_lru_iterator_walks_most_recent_first :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 4)
	defer cache.lru_destroy(&c)

	for i in 1 ..= 3 {
		_ = cache.lru_put(&c, i, i * 10)
	}
	_, _ = cache.lru_get(&c, 1)

	keys: [dynamic]int
	defer delete(keys)
	it := cache.lru_iterator(&c)
	for k, v in cache.lru_iterate(&c, &it) {
		testing.expect_value(t, v, k * 10)
		append(&keys, k)
	}
	testing.expect_value(t, len(keys), 3)
	if len(keys) == 3 {
		testing.expect_value(t, keys[0], 1)
		testing.expect_value(t, keys[1], 3)
		testing.expect_value(t, keys[2], 2)
	}
}

@(test)
test_lru_iterator_skips_expired :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 4, fake_options(&clock))
	defer cache.lru_destroy(&c)

	_ = cache.lru_put_ttl(&c, 1, 1, time.Second)
	_ = cache.lru_put(&c, 2, 2)
	clock.now = time.Minute

	n := 0
	it := cache.lru_iterator(&c)
	for k, _ in cache.lru_iterate(&c, &it) {
		testing.expect_value(t, k, 2)
		n += 1
	}
	testing.expect_value(t, n, 1)
}

@(test)
test_lru_iterator_on_empty_cache :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	it := cache.lru_iterator(&c)
	_, _, ok := cache.lru_iterate(&c, &it)
	testing.expect(t, !ok)
}

@(test)
test_lru_stats_track_operations_and_reset :: proc(t: ^testing.T) {
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 2)
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, 1, 1)
	_ = cache.lru_put(&c, 2, 2)
	_ = cache.lru_put(&c, 3, 3)
	_, _ = cache.lru_get(&c, 3)
	_, _ = cache.lru_get(&c, 1)
	_ = cache.lru_remove(&c, 2)

	s := cache.lru_stats(&c)
	testing.expect_value(t, s, cache.Stats{hits = 1, misses = 1, inserts = 3, evictions = 1, removals = 1})
	testing.expect_value(t, cache.hit_ratio(s), 0.5)

	cache.lru_reset_stats(&c)
	testing.expect_value(t, cache.lru_stats(&c), cache.Stats{})
}

@(test)
test_lru_owned_strings_do_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	c: cache.LRU(string, string)
	testing.expect_value(t, cache.lru_init(&c, 8, allocator = allocator), nil)
	cache.lru_set_evict_callback(&c, free_owned, &allocator)

	for i in 0 ..< 200 {
		key := fmt.aprintf("key-%d", i % 20, allocator = allocator)
		value := fmt.aprintf("value-%d", i, allocator = allocator)
		testing.expect_value(t, cache.lru_put(&c, key, value), nil)
		if i % 7 == 0 {
			_ = cache.lru_remove(&c, "key-5")
		}
		if i % 11 == 0 {
			if k, v, ok := cache.lru_take(&c, "key-3"); ok {
				delete(k, allocator)
				delete(v, allocator)
			}
		}
		if i == 100 {
			_ = cache.lru_resize(&c, 3)
		}
	}
	cache.lru_destroy(&c)
	expect_no_leaks(t, &track)
}

// Model_Entry is one entry of the reference model used by the property tests.
Model_Entry :: struct {
	key:       int,
	value:     int,
	freq:      int,
	last_used: int,
}

model_find :: proc(m: []Model_Entry, key: int) -> int {
	for e, i in m {
		if e.key == key {
			return i
		}
	}
	return -1
}

@(test)
test_lru_matches_reference_model :: proc(t: ^testing.T) {
	state := rand.create(u64(0xC0FFEE))
	context.random_generator = rand.default_random_generator(&state)

	CAP :: 16
	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, CAP)
	defer cache.lru_destroy(&c)

	// The model keeps entries ordered from least to most recently used.
	model: [dynamic]Model_Entry
	defer delete(model)

	for step in 0 ..< 20_000 {
		key := rand.int_max(40)
		switch rand.int_max(10) {
		case 0 ..= 4:
			_ = cache.lru_put(&c, key, step)
			if i := model_find(model[:], key); i >= 0 {
				ordered_remove(&model, i)
			} else if len(model) == CAP {
				ordered_remove(&model, 0)
			}
			append(&model, Model_Entry{key = key, value = step})
		case 5 ..= 7:
			v, ok := cache.lru_get(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				e := model[i]
				testing.expect_value(t, v, e.value)
				ordered_remove(&model, i)
				append(&model, e)
			}
		case 8:
			ok := cache.lru_remove(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				ordered_remove(&model, i)
			}
		case 9:
			v, ok := cache.lru_peek(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				testing.expect_value(t, v, model[i].value)
			}
		}
		if !testing.expect_value(t, cache.lru_len(&c), len(model)) {
			return
		}
	}

	// The iterator must agree with the model's order, most recent first.
	it := cache.lru_iterator(&c)
	i := len(model) - 1
	for k, _ in cache.lru_iterate(&c, &it) {
		testing.expect_value(t, k, model[i].key)
		i -= 1
	}
	testing.expect_value(t, i, -1)
}
