# Storage growth per entry — the WAL plateaus; measure the main file

**Measured at 48362e9, 2026-08-26, with `commonplace_log/scripts/measure_wal_growth.exs`
(1,000 prepared appends of 1,500-byte bodies, one write transaction per entry, fresh data dir).**

| entries | main `.sqlite3` | `.sqlite3-wal` |
|---|---|---|
| 250 | 573,440 | 4,128,272 |
| 500 | 1,073,152 | 4,136,512 |
| 750 | 1,572,864 | 4,144,752 |
| 1000 | 2,076,672 | 4,144,752 |

- The WAL **plateaus at ~4.14 MB ≈ 1,010 pages**. SQLite's default `wal_autocheckpoint` (1,000
  pages) fires, pages are copied into the main file, and the WAL is reused from its start; SQLite
  never shrinks the file, so it sits at its high-water mark. The store sets `journal_mode=WAL` and
  `synchronous=FULL` and leaves autocheckpoint at its default (`local_sqlite.ex`).
- The **main file grows ~2,000 bytes per entry** — canonical bytes plus the row and two indexes,
  ≈ 1.2× the entry — so a browser edit (two entries) costs ≈ 4 KB, durably.
- A 240-entry run (commonplace-doc's #11, ~4 WAL pages per entry) ends at ~960–1,009 pages: inside
  the first ramp to the cap. Read over that window the WAL looks like 34 KB of growth per edit and
  "never checkpointed". Both readings were correct about the window and wrong about the resource.

**Instrument rule, reusable beyond SQLite:** a growth number from a short run needs points *past*
where a cap could sit. Print sizes at N/4 steps; a plateau is the signature of a bounded resource.

**Ruling (commonplace-plan #11, closed):** nothing to fix in the store. `PRAGMA journal_size_limit`
would truncate the WAL after checkpoint — a cosmetic disk-footprint knob, not an I/O change — and is
not added absent a reason. D13b's bytes columns read main-file growth.
