# cache

[![CI](https://github.com/alexisbcz/odin-cache/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-cache/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Generic, fixed-capacity, in-memory caches for Odin: LRU and LFU eviction in O(1), optional TTL expiry, eviction callbacks, statistics and explicit allocators.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-cache libs/cache
```

```odin
import "libs/cache"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-cache ~/odin-shared/cache
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:cache"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:cache"

main :: proc() {
	c: cache.LRU(string, int)
	if err := cache.lru_init(&c, 2); err != nil {
		fmt.eprintln("lru_init failed:", err)
		return
	}
	defer cache.lru_destroy(&c)

	_ = cache.lru_put(&c, "a", 1)
	_ = cache.lru_put(&c, "b", 2)
	_, _ = cache.lru_get(&c, "a")  // "a" is now the most recently used.
	_ = cache.lru_put(&c, "c", 3)  // Evicts "b".

	fmt.println(cache.lru_contains(&c, "b")) // false
}
```

## Choosing a policy

| Type | Evicts | Good for |
| --- | --- | --- |
| `LRU(K, V)` | The least recently used entry | Recency-heavy workloads such as sessions and page caches |
| `LFU(K, V)` | The least frequently used entry, then the least recent among equals | Skewed workloads where a few hot keys matter most |

Both caches allocate their storage once, in `lru_init` or `lfu_init`. After that, `put`, `get`, `remove` and `take` run in O(1) and don't allocate.

## Owning keys and values

A cache stores keys and values by value and never clones them. When they own memory, free it in the eviction callback. Every key and value that a put accepts reaches the callback exactly once, with an `Evict_Reason`:

| Reason | When |
| --- | --- |
| `.Capacity` | The cache was full and the policy chose this entry |
| `.Expired` | The TTL ran out and a get, a purge or a put found it |
| `.Removed` | You called `lru_remove` or `lfu_remove` |
| `.Replaced` | A put stored a new pair under an existing live key; the callback gets the previous pair |
| `.Cleared` | You called a clear or destroy procedure |

`lru_take` and `lfu_take` are the only exception: they return the pair to you without calling the callback.

This excerpt from `examples/basic` caches cloned strings without leaking them:

```odin
free_entry :: proc(key: string, value: string, reason: cache.Evict_Reason, user_data: rawptr) {
	fmt.printfln("evicted %q (%v)", key, reason)
	delete(key)
	delete(value)
}

main :: proc() {
	pages: cache.LRU(string, string)
	if err := cache.lru_init(&pages, 2); err != nil {
		fmt.eprintln("lru_init failed:", err)
		os.exit(1)
	}
	defer cache.lru_destroy(&pages)
	cache.lru_set_evict_callback(&pages, free_entry)
	// ...
}
```

The callback runs after the cache has unlinked the entry. It must not call back into the same cache.

## Expiry

Set `Options.default_ttl` to give every put a TTL, or pass one per entry with `lru_put_ttl` and `lfu_put_ttl`. `NO_EXPIRY` (0) means the entry never expires.

```odin
c: cache.LFU(int, f64)
_ = cache.lfu_init(&c, 1024, cache.Options{default_ttl = time.Minute})
_ = cache.lfu_put_ttl(&c, 42, 0.9, 5 * time.Second)
```

Expired entries leave lazily. A get evicts an expired entry and reports a miss, while peek, contains and the iterators skip it but leave it in place. Call `lru_purge_expired` or `lfu_purge_expired` to free them all at once in O(n).

For tests, set `Options.clock` to a procedure that returns a time you control:

```odin
Fake_Clock :: struct {
	now: time.Duration,
}

fake_now :: proc(data: rawptr) -> time.Duration {
	return (^Fake_Clock)(data).now
}

clock: Fake_Clock
c: cache.LRU(int, int)
_ = cache.lru_init(&c, 8, cache.Options{clock = {procedure = fake_now, data = &clock}})
```

## API overview

Every `lru_*` procedure has an `lfu_*` twin with the same signature.

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `lru_init(c, capacity, options, allocator)` | Allocate the pool and the index | Yes | `lru_destroy` |
| `lru_destroy(c)` | Clear with `.Cleared` callbacks, then free everything | No | Not needed |
| `lru_set_evict_callback(c, callback, user_data)` | Install or remove the eviction callback | No | Not needed |
| `lru_put(c, key, value)` | Insert or replace with the default TTL | No | Callback or `lru_take` |
| `lru_put_ttl(c, key, value, ttl)` | Insert or replace with an explicit TTL | No | Callback or `lru_take` |
| `lru_get(c, key)` | Look up, update recency and count a hit or miss | No | Not needed |
| `lru_get_ptr(c, key)` | Like `lru_get` but returns a pointer into the cache | No | Not needed |
| `lru_peek(c, key)` / `lru_contains(c, key)` | Look up without side effects | No | Not needed |
| `lru_remove(c, key)` | Delete and run the callback | No | Not needed |
| `lru_take(c, key)` | Delete and return the pair to the caller | No | Caller owns the pair |
| `lru_clear(c)` | Delete everything and run the callback | No | Not needed |
| `lru_purge_expired(c)` | Evict every expired entry | No | Not needed |
| `lru_resize(c, capacity)` | Change the capacity, evicting if needed | Yes | `lru_destroy` |
| `lru_iterator(c)` / `lru_iterate(c, &it)` | Walk live entries | No | Not needed |
| `lru_len`, `lru_cap`, `lru_stats`, `lru_reset_stats` | Inspect size and counters | No | Not needed |
| `lfu_frequency(c, key)` | Read an entry's access count (LFU only) | No | Not needed |
| `hit_ratio(stats)` | `hits / (hits + misses)` | No | Not needed |
| `Error` | Union of `Usage_Error` and `runtime.Allocator_Error` | No | Not needed |

`Usage_Error` has the values `.Invalid_Capacity`, `.Invalid_TTL` and `.Not_Initialized`.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- Nodes live in one slice allocated at init and link to each other with 32-bit indices, so a cache is a few allocations in total and entries stay compact.
- The LFU cache keeps one bucket per distinct frequency, in ascending order. A get moves the entry to the next bucket, which is O(1), and the next victim is always at the tail of the first bucket.
- Every allocating procedure takes `allocator := context.allocator` and stores it. Fallible procedures return `Error` and never panic on bad input.
- The package keeps no global mutable state. A cache is safe to use from one thread at a time; wrap it in a `sync.Mutex` to share it.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

The tests include leak checks with `mem.Tracking_Allocator` and randomized runs that compare both caches against a reference model.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
