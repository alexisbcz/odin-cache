package cache

import "base:intrinsics"
import "core:time"

/*
LFU is a fixed-capacity cache that evicts the least frequently used entry.

Each entry counts its accesses: a put inserts it with a frequency of 1, and
every successful get or replacing put adds 1. When the cache is full, it evicts
an entry with the lowest frequency, and among those the least recently used.

All operations are O(1). Entries live in frequency buckets kept in ascending
order, so the next victim is always at the tail of the first bucket.

Create one with lfu_init and release it with lfu_destroy. The fields are
internal; use the procedures in this file instead. A value is safe to use from
one thread at a time.
*/
LFU :: struct($K, $V: typeid) where intrinsics.type_is_comparable(K) {
	index:       map[K]i32,
	nodes:       []Node(K, V),
	buckets:     []Bucket,
	low:         i32,
	high:        i32,
	free_node:   i32,
	free_bucket: i32,
	count:       int,
	options:     Options,
	epoch:       time.Tick,
	on_evict:    proc(key: K, value: V, reason: Evict_Reason, user_data: rawptr),
	user_data:   rawptr,
	stats:       Stats,
	allocator:   Allocator,
}

// Bucket holds the entries that share one access frequency, most recent first.
@(private)
Bucket :: struct {
	freq: u64,
	head: i32,
	tail: i32,
	prev: i32,
	next: i32,
}

/*
lfu_init prepares `c` to hold up to `capacity` entries.

It allocates the node pool, the bucket pool and the index up front, so later
puts do not allocate. Call lfu_destroy when done.

Inputs:
- c: the cache to initialize. Any previous contents are overwritten, not freed.
- capacity: the maximum number of entries, from 1 to MAX_CAPACITY.
- options: default TTL and clock. The zero value disables expiry.
- allocator: used for the pools, the index and any later resize.

Returns:
- err: `.Invalid_Capacity`, `.Invalid_TTL` for a negative default TTL, or an
  allocator error. On error `c` is left zeroed and needs no destroy.
*/
lfu_init :: proc(c: ^LFU($K, $V), capacity: int, options := Options{}, allocator := context.allocator) -> (err: Error) {
	c^ = {}
	validate_options(capacity, options) or_return

	nodes := pool_make(K, V, capacity, allocator) or_return
	buckets, bucket_err := bucket_pool_make(capacity, allocator)
	if bucket_err != nil {
		delete(nodes, allocator)
		return bucket_err
	}
	index, map_err := make(map[K]i32, index_reserve(capacity), allocator)
	if map_err != nil {
		delete(nodes, allocator)
		delete(buckets, allocator)
		return map_err
	}

	c.index = index
	c.nodes = nodes
	c.buckets = buckets
	c.low = NIL
	c.high = NIL
	c.free_node = 0
	c.free_bucket = 0
	c.options = options
	c.epoch = time.tick_now()
	c.allocator = allocator
	return nil
}

/*
lfu_destroy hands every entry to the eviction callback with reason `.Cleared`,
then frees the pools and the index. The cache is zeroed and may be initialized
again. Destroying a zero-value cache is a no-op.
*/
lfu_destroy :: proc(c: ^LFU($K, $V)) {
	lfu_clear(c)
	delete(c.index)
	delete(c.nodes, c.allocator)
	delete(c.buckets, c.allocator)
	c^ = {}
}

/*
lfu_set_evict_callback installs `callback`, which runs once for every entry
that leaves the cache, with the reason. Pass nil to remove it.

The callback runs after the cache has unlinked the entry, so it may free the
key and value. It must not call back into the same cache.
*/
lfu_set_evict_callback :: proc(c: ^LFU($K, $V), callback: proc(key: K, value: V, reason: Evict_Reason, user_data: rawptr), user_data: rawptr = nil) {
	c.on_evict = callback
	c.user_data = user_data
}

/*
lfu_put stores `value` under `key` with the cache's default TTL. See
lfu_put_ttl for the details.
*/
lfu_put :: proc(c: ^LFU($K, $V), key: K, value: V) -> Error {
	return lfu_put_ttl(c, key, value, c.options.default_ttl)
}

/*
lfu_put_ttl stores `value` under `key`.

A new key starts with a frequency of 1. When `key` is already present, the
cache keeps the new key and value, adds 1 to the frequency, and hands the
previous pair to the eviction callback with reason `.Replaced`. When the entry
under `key` has already expired, the cache instead evicts it with reason
`.Expired` and inserts the new pair as a new entry with a frequency of 1. When
the cache is full, it first evicts the least frequently used entry, with reason
`.Expired` if that entry had already expired and `.Capacity` otherwise.

Inputs:
- key, value: stored by value. The cache does not clone them.
- ttl: how long the entry lives. NO_EXPIRY (0) means it never expires.

Returns:
- `.Invalid_TTL` for a negative TTL, `.Not_Initialized` before lfu_init, or an
  allocator error from the index. On error the cache keeps its old contents.
*/
lfu_put_ttl :: proc(c: ^LFU($K, $V), key: K, value: V, ttl: time.Duration) -> Error {
	if ttl < 0 {
		return .Invalid_TTL
	}
	if len(c.nodes) == 0 {
		return .Not_Initialized
	}
	deadline := NEVER
	if ttl > 0 {
		deadline = deadline_after(clock_now(c.options.clock, c.epoch), ttl)
	}

	if i, found := c.index[key]; found && c.nodes[i].deadline != NEVER && is_expired(c.nodes[i].deadline, clock_now(c.options.clock, c.epoch)) {
		// The old pair already expired, so drop it as expired and insert fresh.
		lfu_drop(c, i, .Expired)
	} else if found {
		n := &c.nodes[i]
		old_key, old_value := n.key, n.value
		n.key = key
		n.value = value
		n.deadline = deadline
		// Point the index at the new key, which may own different memory.
		key_ptr, _, _, _ := map_entry(&c.index, key)
		key_ptr^ = key
		lfu_touch(c, i)
		c.stats.updates += 1
		if c.on_evict != nil {
			c.on_evict(old_key, old_value, .Replaced, c.user_data)
		}
		return nil
	}

	if c.count == len(c.nodes) {
		victim := c.buckets[c.low].tail
		reason := Evict_Reason.Capacity
		if is_expired(c.nodes[victim].deadline, clock_now(c.options.clock, c.epoch)) {
			reason = .Expired
		}
		lfu_drop(c, victim, reason)
	}

	i := c.free_node
	_, slot, _, err := map_entry(&c.index, key)
	if err != nil {
		return err
	}
	slot^ = i
	n := &c.nodes[i]
	c.free_node = n.next
	n.key = key
	n.value = value
	n.deadline = deadline

	b := c.low
	if b == NIL || c.buckets[b].freq != 1 {
		b = bucket_alloc(c, 1, NIL)
	}
	n.bucket = b
	list_push_front(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
	c.count += 1
	c.stats.inserts += 1
	return nil
}

/*
lfu_get returns a copy of the value stored under `key` and adds 1 to its
frequency. An expired entry is evicted with reason `.Expired` and reported as
a miss. Updates the hit and miss counters.
*/
lfu_get :: proc(c: ^LFU($K, $V), key: K) -> (value: V, ok: bool) {
	ptr: ^V
	ptr, ok = lfu_get_ptr(c, key)
	if ok {
		value = ptr^
	}
	return
}

/*
lfu_get_ptr behaves like lfu_get but returns a pointer to the stored value, so
large values can be read or changed in place. The pointer stays valid until
the next call that changes the cache.
*/
lfu_get_ptr :: proc(c: ^LFU($K, $V), key: K) -> (value: ^V, ok: bool) {
	i, found := c.index[key]
	if !found {
		c.stats.misses += 1
		return nil, false
	}
	n := &c.nodes[i]
	if n.deadline != NEVER && is_expired(n.deadline, clock_now(c.options.clock, c.epoch)) {
		lfu_drop(c, i, .Expired)
		c.stats.misses += 1
		return nil, false
	}
	lfu_touch(c, i)
	c.stats.hits += 1
	return &n.value, true
}

/*
lfu_peek returns a copy of the value stored under `key` without changing its
frequency or the statistics. It reports an expired entry as absent but leaves
it in place.
*/
lfu_peek :: proc(c: ^LFU($K, $V), key: K) -> (value: V, ok: bool) {
	i, found := c.index[key]
	if !found {
		return
	}
	n := &c.nodes[i]
	if n.deadline != NEVER && is_expired(n.deadline, clock_now(c.options.clock, c.epoch)) {
		return
	}
	return n.value, true
}

// lfu_contains reports whether `key` holds a live entry. Like lfu_peek, it changes nothing.
lfu_contains :: proc(c: ^LFU($K, $V), key: K) -> bool {
	_, ok := lfu_peek(c, key)
	return ok
}

/*
lfu_frequency returns the access count of the live entry under `key` without
changing it. It returns `ok = false` for a missing or expired entry.
*/
lfu_frequency :: proc(c: ^LFU($K, $V), key: K) -> (frequency: u64, ok: bool) {
	i, found := c.index[key]
	if !found {
		return
	}
	n := &c.nodes[i]
	if n.deadline != NEVER && is_expired(n.deadline, clock_now(c.options.clock, c.epoch)) {
		return
	}
	return c.buckets[n.bucket].freq, true
}

/*
lfu_remove deletes the entry under `key` and hands it to the eviction callback
with reason `.Removed`. It returns false when `key` was absent.
*/
lfu_remove :: proc(c: ^LFU($K, $V), key: K) -> bool {
	i, found := c.index[key]
	if !found {
		return false
	}
	lfu_drop(c, i, .Removed)
	return true
}

/*
lfu_take deletes the entry under `key` and returns its key and value to the
caller, who then owns them. The eviction callback does not run. Expired entries
are still returned, because ownership must go somewhere.
*/
lfu_take :: proc(c: ^LFU($K, $V), key: K) -> (stored_key: K, value: V, ok: bool) {
	i, found := c.index[key]
	if !found {
		return
	}
	stored_key, value = c.nodes[i].key, c.nodes[i].value
	lfu_unlink(c, i)
	c.stats.removals += 1
	return stored_key, value, true
}

/*
lfu_clear removes every entry, handing each to the eviction callback with
reason `.Cleared`, in eviction order. Capacity and statistics stay as they are.
*/
lfu_clear :: proc(c: ^LFU($K, $V)) {
	for c.count > 0 {
		lfu_drop(c, c.buckets[c.low].tail, .Cleared)
	}
}

/*
lfu_purge_expired evicts every expired entry with reason `.Expired` and returns
how many it removed. It runs in O(n).
*/
lfu_purge_expired :: proc(c: ^LFU($K, $V)) -> (purged: int) {
	if c.count == 0 {
		return 0
	}
	now := clock_now(c.options.clock, c.epoch)
	for b := c.low; b != NIL; {
		// Dropping the last node of a bucket frees it, so read the link first.
		next_bucket := c.buckets[b].next
		for i := c.buckets[b].tail; i != NIL; {
			prev := c.nodes[i].prev
			if is_expired(c.nodes[i].deadline, now) {
				lfu_drop(c, i, .Expired)
				purged += 1
			}
			i = prev
		}
		b = next_bucket
	}
	return
}

/*
lfu_resize changes the capacity to `capacity`. When shrinking, it evicts
entries in eviction order until the rest fit, with reason `.Expired` for
entries that had already expired and `.Capacity` otherwise.
Frequencies and tie-break order are preserved.

It allocates the new pools with the cache's allocator before touching any
entry, so on error the cache is unchanged.

Returns:
- `.Invalid_Capacity`, `.Not_Initialized`, or an allocator error.
*/
lfu_resize :: proc(c: ^LFU($K, $V), capacity: int) -> Error {
	if capacity <= 0 || capacity > MAX_CAPACITY {
		return .Invalid_Capacity
	}
	if len(c.nodes) == 0 {
		return .Not_Initialized
	}
	if capacity == len(c.nodes) {
		return nil
	}
	nodes := pool_make(K, V, capacity, c.allocator) or_return
	buckets, bucket_err := bucket_pool_make(capacity, c.allocator)
	if bucket_err != nil {
		delete(nodes, c.allocator)
		return bucket_err
	}
	if err := reserve(&c.index, index_reserve(capacity)); err != nil {
		delete(nodes, c.allocator)
		delete(buckets, c.allocator)
		return err
	}

	if c.count > capacity {
		now := clock_now(c.options.clock, c.epoch)
		for c.count > capacity {
			victim := c.buckets[c.low].tail
			reason := Evict_Reason.Expired if is_expired(c.nodes[victim].deadline, now) else .Capacity
			lfu_drop(c, victim, reason)
		}
	}

	low, high := NIL, NIL
	used_nodes, used_buckets := i32(0), i32(0)
	for b := c.low; b != NIL; b = c.buckets[b].next {
		nb := used_buckets
		used_buckets += 1
		buckets[nb] = {
			freq = c.buckets[b].freq,
			head = NIL,
			tail = NIL,
			prev = high,
			next = NIL,
		}
		if high != NIL {
			buckets[high].next = nb
		} else {
			low = nb
		}
		high = nb
		for i := c.buckets[b].tail; i != NIL; i = c.nodes[i].prev {
			j := used_nodes
			used_nodes += 1
			nodes[j].key = c.nodes[i].key
			nodes[j].value = c.nodes[i].value
			nodes[j].deadline = c.nodes[i].deadline
			nodes[j].bucket = nb
			list_push_front(nodes, &buckets[nb].head, &buckets[nb].tail, j)
			c.index[nodes[j].key] = j
		}
	}

	delete(c.nodes, c.allocator)
	delete(c.buckets, c.allocator)
	c.nodes = nodes
	c.buckets = buckets
	c.low = low
	c.high = high
	c.free_node = used_nodes if int(used_nodes) < capacity else NIL
	c.free_bucket = used_buckets if int(used_buckets) < capacity else NIL
	return nil
}

// lfu_len returns the number of entries, including expired ones not yet evicted.
lfu_len :: proc "contextless" (c: ^LFU($K, $V)) -> int {
	return c.count
}

// lfu_cap returns the maximum number of entries, or 0 before lfu_init.
lfu_cap :: proc "contextless" (c: ^LFU($K, $V)) -> int {
	return len(c.nodes)
}

// lfu_stats returns a snapshot of the cache's counters.
lfu_stats :: proc "contextless" (c: ^LFU($K, $V)) -> Stats {
	return c.stats
}

// lfu_reset_stats sets every counter back to zero.
lfu_reset_stats :: proc "contextless" (c: ^LFU($K, $V)) {
	c.stats = {}
}

/*
lfu_iterator returns an iterator over the live entries, from most to least
frequently used, and most recent first within one frequency. Iterating does
not change frequencies or statistics.
*/
lfu_iterator :: proc(c: ^LFU($K, $V)) -> Iterator {
	if c.count == 0 {
		return {node = NIL, bucket = NIL}
	}
	return {node = c.buckets[c.high].head, bucket = c.high, now = clock_now(c.options.clock, c.epoch)}
}

// lfu_iterate returns the next live entry, or `ok = false` when there are no more.
lfu_iterate :: proc(c: ^LFU($K, $V), it: ^Iterator) -> (key: K, value: V, ok: bool) {
	for it.bucket != NIL {
		for it.node != NIL {
			n := &c.nodes[it.node]
			it.node = n.next
			if !is_expired(n.deadline, it.now) {
				return n.key, n.value, true
			}
		}
		it.bucket = c.buckets[it.bucket].prev
		if it.bucket != NIL {
			it.node = c.buckets[it.bucket].head
		}
	}
	return
}

@(private = "file")
bucket_pool_make :: proc(capacity: int, allocator: Allocator) -> (buckets: []Bucket, err: Allocator_Error) {
	buckets = make([]Bucket, capacity, allocator) or_return
	for &b, i in buckets {
		b.head = NIL
		b.tail = NIL
		b.prev = NIL
		b.next = i32(i + 1) if i + 1 < capacity else NIL
	}
	return
}

// bucket_alloc takes a free bucket, sets its frequency and links it after `after`, or first when `after` is NIL.
@(private = "file")
bucket_alloc :: proc "contextless" (c: ^LFU($K, $V), freq: u64, after: i32) -> i32 {
	b := c.free_bucket
	c.free_bucket = c.buckets[b].next
	bucket := &c.buckets[b]
	bucket.freq = freq
	bucket.head = NIL
	bucket.tail = NIL
	bucket.prev = after
	if after == NIL {
		bucket.next = c.low
		c.low = b
	} else {
		bucket.next = c.buckets[after].next
		c.buckets[after].next = b
	}
	if bucket.next != NIL {
		c.buckets[bucket.next].prev = b
	} else {
		c.high = b
	}
	return b
}

// bucket_release unlinks an empty bucket and returns it to the free list.
@(private = "file")
bucket_release :: proc "contextless" (c: ^LFU($K, $V), b: i32) {
	bucket := &c.buckets[b]
	if bucket.prev != NIL {
		c.buckets[bucket.prev].next = bucket.next
	} else {
		c.low = bucket.next
	}
	if bucket.next != NIL {
		c.buckets[bucket.next].prev = bucket.prev
	} else {
		c.high = bucket.prev
	}
	bucket^ = {
		head = NIL,
		tail = NIL,
		prev = NIL,
		next = c.free_bucket,
	}
	c.free_bucket = b
}

/*
lfu_touch adds 1 to the frequency of slot `i`. A new bucket is only taken when
the old one keeps other entries, so the bucket count never exceeds the entry
count and the bucket pool never runs out.
*/
@(private = "file")
lfu_touch :: proc "contextless" (c: ^LFU($K, $V), i: i32) {
	b := c.nodes[i].bucket
	freq := c.buckets[b].freq
	if freq == max(u64) {
		list_unlink(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
		list_push_front(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
		return
	}
	next := c.buckets[b].next
	alone := c.buckets[b].head == i && c.buckets[b].tail == i

	if next != NIL && c.buckets[next].freq == freq + 1 {
		list_unlink(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
		if alone {
			bucket_release(c, b)
		}
		list_push_front(c.nodes, &c.buckets[next].head, &c.buckets[next].tail, i)
		c.nodes[i].bucket = next
		return
	}
	if alone {
		c.buckets[b].freq = freq + 1
		return
	}
	list_unlink(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
	nb := bucket_alloc(c, freq + 1, b)
	list_push_front(c.nodes, &c.buckets[nb].head, &c.buckets[nb].tail, i)
	c.nodes[i].bucket = nb
}

// lfu_unlink removes slot `i` from its bucket and the index and frees the slot.
@(private = "file")
lfu_unlink :: proc(c: ^LFU($K, $V), i: i32) {
	n := &c.nodes[i]
	b := n.bucket
	list_unlink(c.nodes, &c.buckets[b].head, &c.buckets[b].tail, i)
	if c.buckets[b].head == NIL {
		bucket_release(c, b)
	}
	delete_key(&c.index, n.key)
	n.key = {}
	n.value = {}
	n.deadline = 0
	n.bucket = NIL
	n.next = c.free_node
	c.free_node = i
	c.count -= 1
}

// lfu_drop unlinks slot `i`, counts it, then runs the eviction callback.
@(private = "file")
lfu_drop :: proc(c: ^LFU($K, $V), i: i32, reason: Evict_Reason) {
	key, value := c.nodes[i].key, c.nodes[i].value
	lfu_unlink(c, i)
	switch reason {
	case .Capacity:
		c.stats.evictions += 1
	case .Expired:
		c.stats.expirations += 1
	case .Removed:
		c.stats.removals += 1
	case .Replaced, .Cleared:
	}
	if c.on_evict != nil {
		c.on_evict(key, value, reason, c.user_data)
	}
}
