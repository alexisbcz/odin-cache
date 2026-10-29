/*
Package cache provides generic, fixed-capacity, in-memory caches.

Two policies are available, both parametric over the key and value types:

- `LRU` evicts the least recently used entry. Every operation is O(1).
- `LFU` evicts the least frequently used entry, breaking ties by recency.
  Every operation is O(1).

Both caches support optional per-entry time-to-live (TTL) expiry, an eviction
callback that sees every entry leaving the cache, hit and miss statistics, and
an injectable clock for deterministic tests.

Memory: a cache allocates its whole node pool and index once, in `lru_init` or
`lfu_init`, with the allocator passed there. Later operations do not allocate,
except `lru_resize` and `lfu_resize`. The cache stores keys and values by value
and never clones them. When keys or values own memory, free it in the eviction
callback: every key and value that a put accepts reaches the callback exactly
once, unless a take procedure hands it back to the caller first.

Thread safety: a cache is safe to use from one thread at a time. Wrap it in a
`sync.Mutex` to share it.

Example:
	import "shared:cache"

	main :: proc() {
		c: cache.LRU(string, int)
		if err := cache.lru_init(&c, 128); err != nil {
			return
		}
		defer cache.lru_destroy(&c)

		_ = cache.lru_put(&c, "answer", 42)
		if v, ok := cache.lru_get(&c, "answer"); ok {
			assert(v == 42)
		}
	}
*/
package cache

import "base:runtime"
import "core:time"

/*
MAX_CAPACITY is the largest capacity a cache accepts. Node links are 32-bit
indices, which keeps each entry small.
*/
MAX_CAPACITY :: int(max(i32))

/*
NO_EXPIRY is the TTL value that means "never expires". It is the default for
`Options.default_ttl` and is accepted by `lru_put_ttl` and `lfu_put_ttl`.
*/
NO_EXPIRY :: time.Duration(0)

// Usage_Error lists the ways a cache rejects its arguments.
Usage_Error :: enum {
	None,
	// The capacity is zero, negative or larger than MAX_CAPACITY.
	Invalid_Capacity,
	// A TTL is negative. Use NO_EXPIRY for entries that never expire.
	Invalid_TTL,
	// The cache was used before its init procedure succeeded, or after destroy.
	Not_Initialized,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a variant, for example
`cache.Error(cache.Usage_Error.Invalid_TTL)`, or use a type switch.
*/
Error :: union #shared_nil {
	Usage_Error,
	runtime.Allocator_Error,
}

// Evict_Reason tells the eviction callback why an entry left the cache.
Evict_Reason :: enum u8 {
	// The cache was full and the entry was chosen by the eviction policy.
	Capacity,
	// The entry's TTL ran out. Expired entries leave lazily, on access or purge.
	Expired,
	// A remove call deleted the entry.
	Removed,
	// A put stored a new key and value under an existing live key. The callback
	// receives the previous key and value.
	Replaced,
	// A clear or destroy call emptied the cache.
	Cleared,
}

/*
Stats counts what happened to a cache since init or the last reset. Every
counter only grows, so the struct is cheap to snapshot and diff.
*/
Stats :: struct {
	// Lookups through a get procedure that found a live entry.
	hits:        u64,
	// Lookups through a get procedure that found nothing or an expired entry.
	misses:      u64,
	// Puts that added a new key.
	inserts:     u64,
	// Puts that replaced the value of an existing live key.
	updates:     u64,
	// Entries evicted to make room, including those dropped by a resize.
	evictions:   u64,
	// Entries dropped because their TTL ran out.
	expirations: u64,
	// Entries deleted by a remove or take call.
	removals:    u64,
}

/*
hit_ratio returns `hits / (hits + misses)`, or 0 when there were no lookups.
*/
hit_ratio :: proc "contextless" (s: Stats) -> f64 {
	total := s.hits + s.misses
	if total == 0 {
		return 0
	}
	return f64(s.hits) / f64(total)
}

/*
Clock supplies the current time to a cache for TTL checks.

`procedure` returns the time elapsed since any fixed origin, and must never go
backwards. Leave `procedure` nil to use the monotonic system clock. Tests
install a fake clock to control expiry without sleeping.
*/
Clock :: struct {
	procedure: proc(data: rawptr) -> time.Duration,
	data:      rawptr,
}

/*
Options configures a cache at init time. The zero value is valid: no default
TTL and the system clock.
*/
Options :: struct {
	// TTL applied by lru_put and lfu_put. NO_EXPIRY disables expiry.
	default_ttl: time.Duration,
	// Time source for TTL checks. The zero value uses the system clock.
	clock:       Clock,
}

/*
Iterator walks the entries of a cache. Create one with lru_iterator or
lfu_iterator. Any change to the cache invalidates it.
*/
Iterator :: struct {
	node:   i32,
	bucket: i32,
	now:    i64,
}

@(private)
Allocator :: runtime.Allocator

@(private)
Allocator_Error :: runtime.Allocator_Error

@(private)
NIL :: i32(-1)

@(private)
NEVER :: max(i64)

// Node is one slot of a cache's node pool. Free slots chain through `next`.
@(private)
Node :: struct($K, $V: typeid) {
	key:      K,
	value:    V,
	deadline: i64,
	prev:     i32,
	next:     i32,
	bucket:   i32,
}

@(private)
validate_options :: proc(capacity: int, options: Options) -> Error {
	if capacity <= 0 || capacity > MAX_CAPACITY {
		return .Invalid_Capacity
	}
	if options.default_ttl < 0 {
		return .Invalid_TTL
	}
	return nil
}

/*
index_reserve returns how many slots to reserve so that a map holds `capacity`
keys without growing. An Odin map grows once it is 75% full, so reserving only
`capacity` slots would make a later put allocate.
*/
@(private)
index_reserve :: proc "contextless" (capacity: int) -> int {
	extra := capacity / 3 + 1
	if capacity > max(int) - extra {
		return max(int)
	}
	return capacity + extra
}

@(private)
clock_now :: proc(clock: Clock, epoch: time.Tick) -> i64 {
	if clock.procedure != nil {
		return i64(clock.procedure(clock.data))
	}
	return i64(time.tick_since(epoch))
}

// deadline_after returns the absolute deadline for `ttl`, saturating at NEVER.
@(private)
deadline_after :: proc "contextless" (now: i64, ttl: time.Duration) -> i64 {
	if ttl <= 0 {
		return NEVER
	}
	if now > NEVER - i64(ttl) {
		return NEVER
	}
	return now + i64(ttl)
}

@(private)
is_expired :: #force_inline proc "contextless" (deadline, now: i64) -> bool {
	return deadline != NEVER && deadline <= now
}

// pool_make allocates `capacity` nodes and chains them all into a free list.
@(private)
pool_make :: proc($K, $V: typeid, capacity: int, allocator: runtime.Allocator) -> (nodes: []Node(K, V), err: runtime.Allocator_Error) {
	nodes = make([]Node(K, V), capacity, allocator) or_return
	for &n, i in nodes {
		n.prev = NIL
		n.next = i32(i + 1) if i + 1 < capacity else NIL
		n.bucket = NIL
	}
	return
}

@(private)
list_push_front :: proc "contextless" (nodes: []Node($K, $V), head, tail: ^i32, i: i32) {
	nodes[i].prev = NIL
	nodes[i].next = head^
	if head^ != NIL {
		nodes[head^].prev = i
	} else {
		tail^ = i
	}
	head^ = i
}

@(private)
list_unlink :: proc "contextless" (nodes: []Node($K, $V), head, tail: ^i32, i: i32) {
	n := &nodes[i]
	if n.prev != NIL {
		nodes[n.prev].next = n.next
	} else {
		head^ = n.next
	}
	if n.next != NIL {
		nodes[n.next].prev = n.prev
	} else {
		tail^ = n.prev
	}
	n.prev = NIL
	n.next = NIL
}
