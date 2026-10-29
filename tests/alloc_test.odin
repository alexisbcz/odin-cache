package cache_tests

import cache ".."
import "core:mem"
import "core:testing"

// The index must hold `capacity` keys without growing, so puts never allocate.
@(test)
test_lru_full_cache_puts_do_not_allocate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	for capacity in ([]int{1, 7, 48, 64, 100, 1000}) {
		c: cache.LRU(int, int)
		testing.expect_value(t, cache.lru_init(&c, capacity, allocator = mem.tracking_allocator(&track)), nil)
		before := track.total_allocation_count
		for i in 0 ..< capacity * 3 {
			testing.expect_value(t, cache.lru_put(&c, i, i), nil)
		}
		testing.expectf(t, track.total_allocation_count == before, "capacity %d: puts allocated %d times", capacity, track.total_allocation_count - before)
		cache.lru_destroy(&c)
	}
	expect_no_leaks(t, &track)
}

@(test)
test_lfu_full_cache_puts_do_not_allocate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	for capacity in ([]int{1, 7, 48, 64, 100, 1000}) {
		c: cache.LFU(int, int)
		testing.expect_value(t, cache.lfu_init(&c, capacity, allocator = mem.tracking_allocator(&track)), nil)
		before := track.total_allocation_count
		for i in 0 ..< capacity * 3 {
			testing.expect_value(t, cache.lfu_put(&c, i, i), nil)
			_, _ = cache.lfu_get(&c, i)
		}
		testing.expectf(t, track.total_allocation_count == before, "capacity %d: puts allocated %d times", capacity, track.total_allocation_count - before)
		cache.lfu_destroy(&c)
	}
	expect_no_leaks(t, &track)
}

@(test)
test_lru_puts_after_resize_do_not_allocate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	c: cache.LRU(int, int)
	_ = cache.lru_init(&c, 4, allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, cache.lru_resize(&c, 200), nil)
	before := track.total_allocation_count
	for i in 0 ..< 600 {
		_ = cache.lru_put(&c, i, i)
	}
	testing.expect_value(t, track.total_allocation_count - before, 0)
	cache.lru_destroy(&c)
	expect_no_leaks(t, &track)
}

@(test)
test_lfu_puts_after_resize_do_not_allocate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	c: cache.LFU(int, int)
	_ = cache.lfu_init(&c, 4, allocator = mem.tracking_allocator(&track))
	testing.expect_value(t, cache.lfu_resize(&c, 200), nil)
	before := track.total_allocation_count
	for i in 0 ..< 600 {
		_ = cache.lfu_put(&c, i, i)
	}
	testing.expect_value(t, track.total_allocation_count - before, 0)
	cache.lfu_destroy(&c)
	expect_no_leaks(t, &track)
}
