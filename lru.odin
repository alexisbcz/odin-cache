package cache

import "base:intrinsics"
import "core:time"

/*
LRU is a fixed-capacity cache that evicts the least recently used entry.

A put or a successful get marks an entry as most recently used. Lookups,
inserts, updates and removals are all O(1): a map finds the slot and an
index-linked list keeps the recency order.

Create one with lru_init and release it with lru_destroy. The fields are
internal; use the procedures in this file instead. A value is safe to use from
one thread at a time.
*/
LRU :: struct($K, $V: typeid) where intrinsics.type_is_comparable(K) {
	index:     map[K]i32,
	nodes:     []Node(K, V),
	head:      i32,
	tail:      i32,
	free:      i32,
	count:     int,
	options:   Options,
	epoch:     time.Tick,
	on_evict:  proc(key: K, value: V, reason: Evict_Reason, user_data: rawptr),
	user_data: rawptr,
	stats:     Stats,
	allocator: Allocator,
}

/*
lru_init prepares `c` to hold up to `capacity` entries.

It allocates the node pool and reserves the index up front, so later puts do
not allocate. Call lru_destroy when done, even if you never put anything.

Inputs:
- c: the cache to initialize. Any previous contents are overwritten, not freed.
- capacity: the maximum number of entries, from 1 to MAX_CAPACITY.
- options: default TTL and clock. The zero value disables expiry.
- allocator: used for the pool, the index and any later resize.

Returns:
- err: `.Invalid_Capacity`, `.Invalid_TTL` for a negative default TTL, or an
  allocator error. On error `c` is left zeroed and needs no destroy.
*/
lru_init :: proc(c: ^LRU($K, $V), capacity: int, options := Options{}, allocator := context.allocator) -> (err: Error) {
	c^ = {}
	validate_options(capacity, options) or_return

	nodes := pool_make(K, V, capacity, allocator) or_return
	index, map_err := make(map[K]i32, index_reserve(capacity), allocator)
	if map_err != nil {
		delete(nodes, allocator)
		return map_err
	}

	c.index = index
	c.nodes = nodes
	c.head = NIL
	c.tail = NIL
	c.free = 0
	c.options = options
	c.epoch = time.tick_now()
	c.allocator = allocator
	return nil
}

/*
lru_destroy hands every entry to the eviction callback with reason `.Cleared`,
then frees the pool and the index. The cache is zeroed and may be initialized
again. Destroying a zero-value cache is a no-op.
*/
lru_destroy :: proc(c: ^LRU($K, $V)) {
	lru_clear(c)
	delete(c.index)
	delete(c.nodes, c.allocator)
	c^ = {}
}

/*
lru_set_evict_callback installs `callback`, which runs once for every entry
that leaves the cache, with the reason. Pass nil to remove it.

The callback runs after the cache has unlinked the entry, so it may free the
key and value. It must not call back into the same cache.
*/
lru_set_evict_callback :: proc(c: ^LRU($K, $V), callback: proc(key: K, value: V, reason: Evict_Reason, user_data: rawptr), user_data: rawptr = nil) {
	c.on_evict = callback
	c.user_data = user_data
}

/*
lru_put stores `value` under `key` with the cache's default TTL and marks it
most recently used. See lru_put_ttl for the details.
*/
lru_put :: proc(c: ^LRU($K, $V), key: K, value: V) -> Error {
	return lru_put_ttl(c, key, value, c.options.default_ttl)
}

/*
lru_put_ttl stores `value` under `key` and marks it most recently used.

When `key` is already present, the cache keeps the new key and value and hands
the previous pair to the eviction callback with reason `.Replaced`. When the
entry under `key` has already expired, the cache instead evicts it with reason
`.Expired` and inserts the new pair as a new entry. When the cache is full, it
first evicts the least recently used entry, with reason `.Expired` if that
entry had already expired and `.Capacity` otherwise.

Inputs:
- key, value: stored by value. The cache does not clone them.
- ttl: how long the entry lives. NO_EXPIRY (0) means it never expires.

Returns:
- `.Invalid_TTL` for a negative TTL, `.Not_Initialized` before lru_init, or an
  allocator error from the index. On error the cache keeps its old contents.
*/
lru_put_ttl :: proc(c: ^LRU($K, $V), key: K, value: V, ttl: time.Duration) -> Error {
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
		lru_drop(c, i, .Expired)
	} else if found {
		n := &c.nodes[i]
		old_key, old_value := n.key, n.value
		n.key = key
		n.value = value
		n.deadline = deadline
		// Point the index at the new key, which may own different memory.
		key_ptr, _, _, _ := map_entry(&c.index, key)
		key_ptr^ = key
		lru_touch(c, i)
		c.stats.updates += 1
		if c.on_evict != nil {
			c.on_evict(old_key, old_value, .Replaced, c.user_data)
		}
		return nil
	}

	if c.count == len(c.nodes) {
		victim := c.tail
		reason := Evict_Reason.Capacity
		if is_expired(c.nodes[victim].deadline, clock_now(c.options.clock, c.epoch)) {
			reason = .Expired
		}
		lru_drop(c, victim, reason)
	}

	i := c.free
	_, slot, _, err := map_entry(&c.index, key)
	if err != nil {
		return err
	}
	slot^ = i
	n := &c.nodes[i]
	c.free = n.next
	n.key = key
	n.value = value
	n.deadline = deadline
	list_push_front(c.nodes, &c.head, &c.tail, i)
	c.count += 1
	c.stats.inserts += 1
	return nil
}

/*
lru_get returns a copy of the value stored under `key` and marks the entry most
recently used. An expired entry is evicted with reason `.Expired` and reported
as a miss. Updates the hit and miss counters.
*/
lru_get :: proc(c: ^LRU($K, $V), key: K) -> (value: V, ok: bool) {
	ptr: ^V
	ptr, ok = lru_get_ptr(c, key)
	if ok {
		value = ptr^
	}
	return
}

/*
lru_get_ptr behaves like lru_get but returns a pointer to the stored value, so
large values can be read or changed in place. The pointer stays valid until
the next call that changes the cache.
*/
lru_get_ptr :: proc(c: ^LRU($K, $V), key: K) -> (value: ^V, ok: bool) {
	i, found := c.index[key]
	if !found {
		c.stats.misses += 1
		return nil, false
	}
	n := &c.nodes[i]
	if n.deadline != NEVER && is_expired(n.deadline, clock_now(c.options.clock, c.epoch)) {
		lru_drop(c, i, .Expired)
		c.stats.misses += 1
		return nil, false
	}
	lru_touch(c, i)
	c.stats.hits += 1
	return &n.value, true
}

/*
lru_peek returns a copy of the value stored under `key` without changing its
recency or the statistics. It reports an expired entry as absent but leaves it
in place.
*/
lru_peek :: proc(c: ^LRU($K, $V), key: K) -> (value: V, ok: bool) {
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

// lru_contains reports whether `key` holds a live entry. Like lru_peek, it changes nothing.
lru_contains :: proc(c: ^LRU($K, $V), key: K) -> bool {
	_, ok := lru_peek(c, key)
	return ok
}

/*
lru_remove deletes the entry under `key` and hands it to the eviction callback
with reason `.Removed`. It returns false when `key` was absent.
*/
lru_remove :: proc(c: ^LRU($K, $V), key: K) -> bool {
	i, found := c.index[key]
	if !found {
		return false
	}
	lru_drop(c, i, .Removed)
	return true
}

/*
lru_take deletes the entry under `key` and returns its key and value to the
caller, who then owns them. The eviction callback does not run. Expired entries
are still returned, because ownership must go somewhere.
*/
lru_take :: proc(c: ^LRU($K, $V), key: K) -> (stored_key: K, value: V, ok: bool) {
	i, found := c.index[key]
	if !found {
		return
	}
	stored_key, value = c.nodes[i].key, c.nodes[i].value
	lru_unlink(c, i)
	c.stats.removals += 1
	return stored_key, value, true
}

/*
lru_clear removes every entry, handing each to the eviction callback with
reason `.Cleared`, from least to most recently used. Capacity and statistics
stay as they are.
*/
lru_clear :: proc(c: ^LRU($K, $V)) {
	for c.count > 0 {
		lru_drop(c, c.tail, .Cleared)
	}
}

/*
lru_purge_expired evicts every expired entry with reason `.Expired` and returns
how many it removed. It runs in O(n); call it periodically when expired
entries should release their memory before they are next looked up.
*/
lru_purge_expired :: proc(c: ^LRU($K, $V)) -> (purged: int) {
	if c.count == 0 {
		return 0
	}
	now := clock_now(c.options.clock, c.epoch)
	for i := c.tail; i != NIL; {
		prev := c.nodes[i].prev
		if is_expired(c.nodes[i].deadline, now) {
			lru_drop(c, i, .Expired)
			purged += 1
		}
		i = prev
	}
	return
}

/*
lru_resize changes the capacity to `capacity`. When shrinking, it evicts the
least recently used entries until the rest fit, with reason `.Expired` for
entries that had already expired and `.Capacity` otherwise.
Recency order is preserved.

It allocates a new pool with the cache's allocator before touching any entry,
so on error the cache is unchanged.

Returns:
- `.Invalid_Capacity`, `.Not_Initialized`, or an allocator error.
*/
lru_resize :: proc(c: ^LRU($K, $V), capacity: int) -> Error {
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
	if err := reserve(&c.index, index_reserve(capacity)); err != nil {
		delete(nodes, c.allocator)
		return err
	}

	if c.count > capacity {
		now := clock_now(c.options.clock, c.epoch)
		for c.count > capacity {
			reason := Evict_Reason.Expired if is_expired(c.nodes[c.tail].deadline, now) else .Capacity
			lru_drop(c, c.tail, reason)
		}
	}

	head, tail := NIL, NIL
	used := i32(0)
	for i := c.tail; i != NIL; i = c.nodes[i].prev {
		j := used
		used += 1
		nodes[j].key = c.nodes[i].key
		nodes[j].value = c.nodes[i].value
		nodes[j].deadline = c.nodes[i].deadline
		list_push_front(nodes, &head, &tail, j)
		c.index[nodes[j].key] = j
	}

	delete(c.nodes, c.allocator)
	c.nodes = nodes
	c.head = head
	c.tail = tail
	c.free = used if int(used) < capacity else NIL
	return nil
}

// lru_len returns the number of entries, including expired ones not yet evicted.
lru_len :: proc "contextless" (c: ^LRU($K, $V)) -> int {
	return c.count
}

// lru_cap returns the maximum number of entries, or 0 before lru_init.
lru_cap :: proc "contextless" (c: ^LRU($K, $V)) -> int {
	return len(c.nodes)
}

// lru_stats returns a snapshot of the cache's counters.
lru_stats :: proc "contextless" (c: ^LRU($K, $V)) -> Stats {
	return c.stats
}

// lru_reset_stats sets every counter back to zero.
lru_reset_stats :: proc "contextless" (c: ^LRU($K, $V)) {
	c.stats = {}
}

/*
lru_iterator returns an iterator over the live entries, from most to least
recently used. Iterating does not change recency or statistics.

Example:
	it := cache.lru_iterator(&c)
	for key, value in cache.lru_iterate(&c, &it) {
		fmt.println(key, value)
	}
*/
lru_iterator :: proc(c: ^LRU($K, $V)) -> Iterator {
	if c.count == 0 {
		return {node = NIL, bucket = NIL}
	}
	return {node = c.head, bucket = NIL, now = clock_now(c.options.clock, c.epoch)}
}

// lru_iterate returns the next live entry, or `ok = false` when there are no more.
lru_iterate :: proc(c: ^LRU($K, $V), it: ^Iterator) -> (key: K, value: V, ok: bool) {
	for it.node != NIL {
		n := &c.nodes[it.node]
		it.node = n.next
		if !is_expired(n.deadline, it.now) {
			return n.key, n.value, true
		}
	}
	return
}

// lru_touch moves slot `i` to the most recently used position.
@(private = "file")
lru_touch :: proc "contextless" (c: ^LRU($K, $V), i: i32) {
	if c.head == i {
		return
	}
	list_unlink(c.nodes, &c.head, &c.tail, i)
	list_push_front(c.nodes, &c.head, &c.tail, i)
}

// lru_unlink removes slot `i` from the list and the index and frees the slot.
@(private = "file")
lru_unlink :: proc(c: ^LRU($K, $V), i: i32) {
	n := &c.nodes[i]
	list_unlink(c.nodes, &c.head, &c.tail, i)
	delete_key(&c.index, n.key)
	n.key = {}
	n.value = {}
	n.deadline = 0
	n.next = c.free
	c.free = i
	c.count -= 1
}

// lru_drop unlinks slot `i`, counts it, then runs the eviction callback.
@(private = "file")
lru_drop :: proc(c: ^LRU($K, $V), i: i32, reason: Evict_Reason) {
	key, value := c.nodes[i].key, c.nodes[i].value
	lru_unlink(c, i)
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
