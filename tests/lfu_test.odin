package cache_tests

import cache ".."
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:testing"
import "core:time"

@(test)
test_lfu_init_rejects_bad_options :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	testing.expect_value(t, cache.lfu_init(&c, 0), Error(Usage_Error.Invalid_Capacity))
	testing.expect_value(t, cache.lfu_init(&c, -1), Error(Usage_Error.Invalid_Capacity))
	testing.expect_value(t, cache.lfu_init(&c, 2, cache.Options{default_ttl = -1}), Error(Usage_Error.Invalid_TTL))
	testing.expect_value(t, cache.lfu_cap(&c), 0)
}

@(test)
test_lfu_init_reports_allocator_failure :: proc(t: ^testing.T) {
	buf: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	c: cache.LFU(int, int)
	err := cache.lfu_init(&c, 1000, allocator = mem.arena_allocator(&arena))
	testing.expect_value(t, err, Error(mem.Allocator_Error.Out_Of_Memory))
}

@(test)
test_lfu_put_before_init_is_rejected :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	testing.expect_value(t, cache.lfu_put(&c, 1, 1), Error(Usage_Error.Not_Initialized))
	cache.lfu_destroy(&c)
}

@(test)
test_lfu_put_then_get_returns_value :: proc(t: ^testing.T) {
	c: cache.LFU(string, int)
	testing.expect_value(t, cache.lfu_init(&c, 4), nil)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, "a", 1)
	v, ok := cache.lfu_get(&c, "a")
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)
	_, ok = cache.lfu_get(&c, "b")
	testing.expect(t, !ok)
	testing.expect_value(t, cache.lfu_stats(&c), cache.Stats{hits = 1, misses = 1, inserts = 1})
}

@(test)
test_lfu_evicts_least_frequently_used :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put(&c, 1, 10)
	_ = cache.lfu_put(&c, 2, 20)
	_, _ = cache.lfu_get(&c, 2)
	_, _ = cache.lfu_get(&c, 2)
	_, _ = cache.lfu_get(&c, 1)
	_ = cache.lfu_put(&c, 3, 30)

	testing.expect(t, !cache.lfu_contains(&c, 1))
	testing.expect(t, cache.lfu_contains(&c, 2))
	testing.expect(t, cache.lfu_contains(&c, 3))
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Capacity})
}

@(test)
test_lfu_breaks_ties_by_recency :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 3)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, 1, 1)
	_ = cache.lfu_put(&c, 2, 2)
	_ = cache.lfu_put(&c, 3, 3)
	// All three have frequency 2; 2 reached it first, so it goes first.
	_, _ = cache.lfu_get(&c, 2)
	_, _ = cache.lfu_get(&c, 3)
	_, _ = cache.lfu_get(&c, 1)
	_ = cache.lfu_put(&c, 4, 4)

	testing.expect(t, !cache.lfu_contains(&c, 2))
	testing.expect(t, cache.lfu_contains(&c, 1))
	testing.expect(t, cache.lfu_contains(&c, 3))
}

@(test)
test_lfu_new_entry_is_evicted_before_hot_ones :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, 1, 1)
	for _ in 0 ..< 5 {
		_, _ = cache.lfu_get(&c, 1)
	}
	for k in 2 ..< 10 {
		_ = cache.lfu_put(&c, k, k)
	}
	testing.expect(t, cache.lfu_contains(&c, 1))
	testing.expect(t, cache.lfu_contains(&c, 9))
	testing.expect_value(t, cache.lfu_stats(&c).evictions, 7)
}

@(test)
test_lfu_frequency_counts_gets_and_replacing_puts :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put(&c, 1, 10)
	f, ok := cache.lfu_frequency(&c, 1)
	testing.expect(t, ok)
	testing.expect_value(t, f, 1)

	_, _ = cache.lfu_get(&c, 1)
	_ = cache.lfu_put(&c, 1, 11)
	_, _ = cache.lfu_peek(&c, 1)
	f, _ = cache.lfu_frequency(&c, 1)
	testing.expect_value(t, f, 3)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Replaced})

	_, ok = cache.lfu_frequency(&c, 2)
	testing.expect(t, !ok)
}

@(test)
test_lfu_get_ptr_allows_in_place_update :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, 1, 10)
	if p, ok := cache.lfu_get_ptr(&c, 1); testing.expect(t, ok) {
		p^ += 5
	}
	v, _ := cache.lfu_peek(&c, 1)
	testing.expect_value(t, v, 15)
}

@(test)
test_lfu_remove_and_take :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 3)
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put(&c, 1, 10)
	_ = cache.lfu_put(&c, 2, 20)
	_, _ = cache.lfu_get(&c, 2)

	testing.expect(t, cache.lfu_remove(&c, 1))
	testing.expect(t, !cache.lfu_remove(&c, 1))
	k, v, ok := cache.lfu_take(&c, 2)
	testing.expect(t, ok)
	testing.expect_value(t, k, 2)
	testing.expect_value(t, v, 20)
	_, _, ok = cache.lfu_take(&c, 2)
	testing.expect(t, !ok)

	testing.expect_value(t, cache.lfu_len(&c), 0)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Removed})
	testing.expect_value(t, cache.lfu_stats(&c).removals, 2)
}

@(test)
test_lfu_entry_expires_after_ttl :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2, fake_options(&clock, time.Second))
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put(&c, 1, 10)
	_ = cache.lfu_put_ttl(&c, 2, 20, cache.NO_EXPIRY)
	clock.now = time.Second
	_, ok := cache.lfu_get(&c, 1)
	testing.expect(t, !ok)
	_, ok = cache.lfu_frequency(&c, 2)
	testing.expect(t, ok)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event{1, 10, .Expired})
	testing.expect_value(t, cache.lfu_stats(&c).expirations, 1)
}

@(test)
test_lfu_put_ttl_rejects_negative_ttl :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)
	testing.expect_value(t, cache.lfu_put_ttl(&c, 1, 1, -time.Second), Error(Usage_Error.Invalid_TTL))
}

@(test)
test_lfu_peek_and_frequency_hide_expired :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2, fake_options(&clock))
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put_ttl(&c, 1, 1, time.Second)
	clock.now = time.Minute
	_, ok := cache.lfu_peek(&c, 1)
	testing.expect(t, !ok)
	_, ok = cache.lfu_frequency(&c, 1)
	testing.expect(t, !ok)
	testing.expect_value(t, cache.lfu_len(&c), 1)
}

@(test)
test_lfu_purge_expired_across_buckets :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 8, fake_options(&clock))
	defer cache.lfu_destroy(&c)

	for k in 0 ..< 6 {
		ttl := time.Second if k % 2 == 0 else cache.NO_EXPIRY
		_ = cache.lfu_put_ttl(&c, k, k, ttl)
		for _ in 0 ..< k {
			_, _ = cache.lfu_get(&c, k)
		}
	}
	clock.now = 2 * time.Second
	testing.expect_value(t, cache.lfu_purge_expired(&c), 3)
	testing.expect_value(t, cache.lfu_len(&c), 3)
	for k in 0 ..< 6 {
		testing.expect_value(t, cache.lfu_contains(&c, k), k % 2 == 1)
	}
	f, _ := cache.lfu_frequency(&c, 5)
	testing.expect_value(t, f, 6)
}

@(test)
test_lfu_full_cache_reports_expired_victim :: proc(t: ^testing.T) {
	clock: Fake_Clock
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 1, fake_options(&clock))
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put_ttl(&c, 1, 10, time.Second)
	clock.now = time.Minute
	_ = cache.lfu_put(&c, 2, 20)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].reason, cache.Evict_Reason.Expired)
}

@(test)
test_lfu_clear_empties_and_stays_usable :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 3)
	defer cache.lfu_destroy(&c)

	events: [dynamic]Event
	defer delete(events)
	cache.lfu_set_evict_callback(&c, record_event, &events)

	_ = cache.lfu_put(&c, 1, 10)
	_ = cache.lfu_put(&c, 2, 20)
	_, _ = cache.lfu_get(&c, 1)
	cache.lfu_clear(&c)
	testing.expect_value(t, cache.lfu_len(&c), 0)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0], Event{2, 20, .Cleared})
	testing.expect_value(t, events[1], Event{1, 10, .Cleared})

	for k in 0 ..< 3 {
		testing.expect_value(t, cache.lfu_put(&c, k, k), nil)
	}
	f, _ := cache.lfu_frequency(&c, 1)
	testing.expect_value(t, f, 1)
}

@(test)
test_lfu_resize_shrink_keeps_hot_entries :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 4)
	defer cache.lfu_destroy(&c)

	for k in 1 ..= 4 {
		_ = cache.lfu_put(&c, k, k)
		for _ in 0 ..< k {
			_, _ = cache.lfu_get(&c, k)
		}
	}
	testing.expect_value(t, cache.lfu_resize(&c, 2), nil)
	testing.expect_value(t, cache.lfu_len(&c), 2)
	testing.expect_value(t, cache.lfu_cap(&c), 2)
	testing.expect(t, cache.lfu_contains(&c, 3))
	testing.expect(t, cache.lfu_contains(&c, 4))
	f, _ := cache.lfu_frequency(&c, 4)
	testing.expect_value(t, f, 5)

	_ = cache.lfu_put(&c, 5, 5)
	testing.expect(t, cache.lfu_contains(&c, 4))
	testing.expect(t, !cache.lfu_contains(&c, 3))
}

@(test)
test_lfu_resize_grow_keeps_entries :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, 1, 1)
	_ = cache.lfu_put(&c, 2, 2)
	_, _ = cache.lfu_get(&c, 2)
	testing.expect_value(t, cache.lfu_resize(&c, 5), nil)
	for k in 3 ..= 5 {
		_ = cache.lfu_put(&c, k, k)
	}
	testing.expect_value(t, cache.lfu_len(&c), 5)
	f, _ := cache.lfu_frequency(&c, 2)
	testing.expect_value(t, f, 2)
	testing.expect_value(t, cache.lfu_stats(&c).evictions, 0)
}

@(test)
test_lfu_resize_rejects_bad_arguments :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	testing.expect_value(t, cache.lfu_resize(&c, 2), Error(Usage_Error.Not_Initialized))
	_ = cache.lfu_init(&c, 2)
	defer cache.lfu_destroy(&c)
	testing.expect_value(t, cache.lfu_resize(&c, cache.MAX_CAPACITY + 1), Error(Usage_Error.Invalid_Capacity))
}

@(test)
test_lfu_iterator_walks_most_frequent_first :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 4)
	defer cache.lfu_destroy(&c)

	_ = cache.lfu_put(&c, 1, 1)
	_ = cache.lfu_put(&c, 2, 2)
	_ = cache.lfu_put(&c, 3, 3)
	_, _ = cache.lfu_get(&c, 3)
	_, _ = cache.lfu_get(&c, 3)
	_, _ = cache.lfu_get(&c, 1)

	expected := [3]int{3, 1, 2}
	n := 0
	it := cache.lfu_iterator(&c)
	for k, v in cache.lfu_iterate(&c, &it) {
		testing.expect_value(t, k, v)
		if n < 3 {
			testing.expect_value(t, k, expected[n])
		}
		n += 1
	}
	testing.expect_value(t, n, 3)
}

@(test)
test_lfu_iterator_on_zero_value_cache :: proc(t: ^testing.T) {
	c: cache.LFU(int, int)
	it := cache.lfu_iterator(&c)
	_, _, ok := cache.lfu_iterate(&c, &it)
	testing.expect(t, !ok)
}

@(test)
test_lfu_owned_strings_do_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	c: cache.LFU(string, string)
	testing.expect_value(t, cache.lfu_init(&c, 8, allocator = allocator), nil)
	cache.lfu_set_evict_callback(&c, free_owned, &allocator)

	for i in 0 ..< 200 {
		key := fmt.aprintf("key-%d", i % 20, allocator = allocator)
		value := fmt.aprintf("value-%d", i, allocator = allocator)
		testing.expect_value(t, cache.lfu_put(&c, key, value), nil)
		_, _ = cache.lfu_get(&c, "key-1")
		if i % 7 == 0 {
			_ = cache.lfu_remove(&c, "key-5")
		}
		if i % 11 == 0 {
			if k, v, ok := cache.lfu_take(&c, "key-3"); ok {
				delete(k, allocator)
				delete(v, allocator)
			}
		}
		if i == 100 {
			_ = cache.lfu_resize(&c, 3)
		}
	}
	cache.lfu_destroy(&c)
	expect_no_leaks(t, &track)
}

@(test)
test_lfu_matches_reference_model :: proc(t: ^testing.T) {
	state := rand.create(u64(0xBADCAFE))
	context.random_generator = rand.default_random_generator(&state)

	CAP :: 16
	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, CAP)
	defer cache.lfu_destroy(&c)

	// The victim is the entry with the lowest frequency, then the oldest access.
	model: [dynamic]Model_Entry
	defer delete(model)

	for step in 0 ..< 20_000 {
		key := rand.int_max(40)
		switch rand.int_max(10) {
		case 0 ..= 4:
			_ = cache.lfu_put(&c, key, step)
			if i := model_find(model[:], key); i >= 0 {
				model[i].value = step
				model[i].freq += 1
				model[i].last_used = step
				break
			}
			if len(model) == CAP {
				victim := 0
				for e, i in model {
					v := model[victim]
					if e.freq < v.freq || (e.freq == v.freq && e.last_used < v.last_used) {
						victim = i
					}
				}
				unordered_remove(&model, victim)
			}
			append(&model, Model_Entry{key = key, value = step, freq = 1, last_used = step})
		case 5 ..= 7:
			v, ok := cache.lfu_get(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				testing.expect_value(t, v, model[i].value)
				model[i].freq += 1
				model[i].last_used = step
			}
		case 8:
			ok := cache.lfu_remove(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				unordered_remove(&model, i)
			}
		case 9:
			f, ok := cache.lfu_frequency(&c, key)
			i := model_find(model[:], key)
			testing.expect_value(t, ok, i >= 0)
			if i >= 0 {
				testing.expect_value(t, int(f), model[i].freq)
			}
		}
		if !testing.expect_value(t, cache.lfu_len(&c), len(model)) {
			return
		}
	}
}
