// Example basic shows an LRU cache that owns its strings and an LFU cache with
// a TTL. Run it with `odin run examples/basic`.
package main

import cache "../.."
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// free_entry runs for every entry that leaves the cache, so the cache can own
// the cloned strings without leaking them.
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

	for path in ([]string{"/", "/about", "/", "/blog"}) {
		if body, ok := cache.lru_get(&pages, path); ok {
			fmt.printfln("hit  %s -> %s", path, body)
			continue
		}
		body := strings.concatenate({"<html>", path, "</html>"})
		fmt.printfln("miss %s", path)
		if err := cache.lru_put(&pages, strings.clone(path), body); err != nil {
			fmt.eprintln("lru_put failed:", err)
			os.exit(1)
		}
	}
	stats := cache.lru_stats(&pages)
	fmt.printfln("hits=%d misses=%d ratio=%.2f", stats.hits, stats.misses, cache.hit_ratio(stats))

	// An LFU cache keeps popular entries; the TTL bounds how stale they get.
	scores: cache.LFU(int, f64)
	if err := cache.lfu_init(&scores, 2, cache.Options{default_ttl = time.Minute}); err != nil {
		fmt.eprintln("lfu_init failed:", err)
		os.exit(1)
	}
	defer cache.lfu_destroy(&scores)

	_ = cache.lfu_put(&scores, 1, 0.5)
	_ = cache.lfu_put(&scores, 2, 0.7)
	_, _ = cache.lfu_get(&scores, 1)
	_ = cache.lfu_put(&scores, 3, 0.9) // Evicts 2, the least frequently used.
	fmt.println("2 cached:", cache.lfu_contains(&scores, 2))
}
