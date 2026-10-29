# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- Puts no longer allocate after init or resize. The index reserved space for only `capacity` keys, but an Odin map grows once it is 75% full, so filling a cache of 7 or more entries caused one hidden allocation.
- A put over an expired entry now evicts the old pair with reason `.Expired` and inserts the new pair as a new entry. Before, it reported `.Replaced`, counted an update, and in `LFU` kept the old frequency, so a stale entry came back as hot.
- A shrinking resize now reports entries that had already expired with reason `.Expired` and counts them in `Stats.expirations`, not as capacity evictions.

## [0.1.0] - 2026-10-29

### Added

- `LRU(K, V)`, a fixed-capacity least recently used cache with O(1) put, get, remove and take.
- `LFU(K, V)`, a fixed-capacity least frequently used cache with O(1) operations and recency as the tie-break.
- Per-entry and default TTL expiry, lazy eviction of expired entries and `purge_expired` procedures.
- Eviction callbacks with an `Evict_Reason`, so caches can own keys and values that allocate.
- `Stats` counters and `hit_ratio`.
- A `Clock` option that lets tests control time without sleeping.
- `resize` procedures, iterators, `peek`, `contains`, `get_ptr` and `lfu_frequency`.
- `Error`, a union of `Usage_Error` and `runtime.Allocator_Error`.

[Unreleased]: https://github.com/alexisbcz/odin-cache/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-cache/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-cache/releases/tag/v0.1.0
