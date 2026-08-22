/**
 * Pure merge classification per spec §9.3 (rules 1–6 and the three merge
 * error codes), §6.3 (entry-ID collision), §8 invariants 3/4/9/10.
 *
 * This module is a pure function over already-validated, canonicalized
 * entries: no database, no I/O, runtime-neutral (runs identically in node
 * and workerd). `store.ts` executes the returned plan inside one
 * transaction; execution concerns stay out of here. An error outcome refuses
 * the WHOLE batch — it carries no per-writer plan, so no partial write can
 * be derived from it (invariant 10).
 */

/** A writer's current local tip as known to the store. */
export interface TipInfo {
  seq: number;
  entryId: string;
}

/** One validated batch entry: parsed fields plus its canonical bytes. */
export interface BatchEntry {
  entryId: string;
  writerId: string;
  writerSeq: number;
  prevEntryId: string | null;
  canonicalBytes: Uint8Array;
}

export type MergeOutcome =
  | {
      ok: true;
      /** One plan per writer with new entries, sorted by writerId. Writers
       * whose batch entries were all already present are omitted. */
      perWriter: Array<{
        writerId: string;
        firstNewSeq: number;
        newEntries: BatchEntry[];
      }>;
      /** Entries accepted as already present (§9.3 rule 2) plus exact
       * intra-batch duplicates, so inserted + present covers the batch. */
      presentCount: number;
    }
  | {
      ok: false;
      code: "writer_gap";
      details: {
        writerId: string;
        expectedSeq: number;
        tipEntryId: string | null;
      };
    }
  | {
      ok: false;
      code: "writer_fork";
      details: { writerId: string; seq: number };
    }
  | {
      ok: false;
      code: "entry_id_collision";
      details: { entryId: string };
    }
  | {
      // Internal-only code — §11.6 has no "invalid_batch". Wire mapping:
      // 422 invalid_entry (an intra-batch prev-linkage violation breaks §7's
      // relational requirement between consecutive entries; the batch is
      // malformed as submitted, unlike gap/fork which are receiver-state
      // conflicts) — see plan Task 7.
      ok: false;
      code: "invalid_batch";
      details: { reason: string };
    };

/** Byte-equality without node's Buffer; the module stays runtime-neutral. */
function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/**
 * Classify a validated batch against the store's current per-writer tips.
 *
 * @param batch    Validated entries (any order; §9.3 rule 1 sorting is ours).
 * @param existing Per-writer tips known to the store; absent = fresh writer.
 * @param presentByCoord Canonical bytes already stored at (writer, seq), or
 *                       null when the coordinate is unoccupied.
 * @param presentById    Stored entry owning an entry_id, or null.
 */
export function planMerge(
  batch: BatchEntry[],
  existing: Map<string, TipInfo>,
  presentByCoord: (w: string, s: number) => Uint8Array | null,
  presentById: (
    id: string,
  ) => { writerId: string; writerSeq: number; bytes: Uint8Array } | null,
): MergeOutcome {
  const byWriter = new Map<string, BatchEntry[]>();
  for (const entry of batch) {
    const group = byWriter.get(entry.writerId);
    if (group) group.push(entry);
    else byWriter.set(entry.writerId, [entry]);
  }

  // Deterministic processing order: writers sorted by writerId. The first
  // failing writer's error is the batch's error.
  const writerIds = [...byWriter.keys()].sort();

  // Intra-batch entry_id registry, global across writers (§8 invariant 4).
  const seenIds = new Map<string, BatchEntry>();

  const perWriter: Array<{
    writerId: string;
    firstNewSeq: number;
    newEntries: BatchEntry[];
  }> = [];
  let presentCount = 0;

  for (const writerId of writerIds) {
    // §9.3 rule 1: sort entries by writer_seq.
    const entries = byWriter
      .get(writerId)!
      .slice()
      .sort((a, b) => a.writerSeq - b.writerSeq);

    const tip = existing.get(writerId);
    const tipSeq = tip?.seq ?? 0;
    const tipEntryId = tip?.entryId ?? null;

    // Pass 1 — identity checks and intra-batch deduplication.
    // §6.3: an entry_id reused for different bytes (or a different
    // coordinate, which implies different bytes) MUST be rejected as a
    // collision, whether the prior owner is in the store or earlier in this
    // batch. An exact repeat (same id, same coordinate, byte-equal) is
    // deduplicated and its copy counted as present.
    const deduped: BatchEntry[] = [];
    for (const entry of entries) {
      const prior = seenIds.get(entry.entryId);
      if (prior) {
        if (
          prior.writerId === entry.writerId &&
          prior.writerSeq === entry.writerSeq &&
          bytesEqual(prior.canonicalBytes, entry.canonicalBytes)
        ) {
          presentCount++;
          continue;
        }
        return {
          ok: false,
          code: "entry_id_collision",
          details: { entryId: entry.entryId },
        };
      }
      const stored = presentById(entry.entryId);
      if (
        stored &&
        (stored.writerId !== entry.writerId ||
          stored.writerSeq !== entry.writerSeq ||
          !bytesEqual(stored.bytes, entry.canonicalBytes))
      ) {
        return {
          ok: false,
          code: "entry_id_collision",
          details: { entryId: entry.entryId },
        };
      }
      seenIds.set(entry.entryId, entry);

      // Two distinct entries at one coordinate inside the batch: the
      // coordinate can hold at most one entry (§8 invariant 3), so the
      // batch itself contains a fork. Exact repeats were consumed above,
      // and after sorting equal seqs are adjacent.
      const last = deduped[deduped.length - 1];
      if (last && last.writerSeq === entry.writerSeq) {
        return {
          ok: false,
          code: "writer_fork",
          details: { writerId, seq: entry.writerSeq },
        };
      }
      deduped.push(entry);
    }

    // Pass 2 — classify present vs new; chain-check the new segment.
    const newEntries: BatchEntry[] = [];
    for (const entry of deduped) {
      if (entry.writerSeq <= tipSeq) {
        // §9.3 rule 2: an exact duplicate of a stored entry is present.
        // Anything else at an occupied coordinate is a fork. A coordinate
        // at or below the tip is occupied by invariant 5, so a null lookup
        // is a store inconsistency; classify it like a mismatch rather
        // than inventing an insert over unknown state.
        const storedBytes = presentByCoord(writerId, entry.writerSeq);
        if (storedBytes === null || !bytesEqual(storedBytes, entry.canonicalBytes)) {
          return {
            ok: false,
            code: "writer_fork",
            details: { writerId, seq: entry.writerSeq },
          };
        }
        presentCount++;
        continue;
      }

      const preceding = newEntries[newEntries.length - 1];
      if (!preceding) {
        // §9.3 rule 3: the first new entry is exactly one after the tip.
        if (entry.writerSeq !== tipSeq + 1) {
          return {
            ok: false,
            code: "writer_gap",
            details: { writerId, expectedSeq: tipSeq + 1, tipEntryId },
          };
        }
        // §9.3 rule 4: its prev_entry_id equals the local tip UUID (null
        // for a fresh writer's entry 1). A mismatch at the right sequence
        // means the coordinate would hold a different chain: writer_fork.
        if (entry.prevEntryId !== tipEntryId) {
          return {
            ok: false,
            code: "writer_fork",
            details: { writerId, seq: entry.writerSeq },
          };
        }
      } else {
        // §9.3 rule 5: every subsequent entry increments by one — a hole
        // after the first new entry is a gap at the hole — and names the
        // preceding batch entry — a wrong link is intra-batch incoherence.
        if (entry.writerSeq !== preceding.writerSeq + 1) {
          return {
            ok: false,
            code: "writer_gap",
            details: {
              writerId,
              expectedSeq: preceding.writerSeq + 1,
              tipEntryId,
            },
          };
        }
        if (entry.prevEntryId !== preceding.entryId) {
          return {
            ok: false,
            code: "invalid_batch",
            details: {
              reason:
                `writer ${writerId} seq ${entry.writerSeq}: prev_entry_id ` +
                `does not name the preceding batch entry`,
            },
          };
        }
      }
      newEntries.push(entry);
    }

    if (newEntries.length > 0) {
      perWriter.push({ writerId, firstNewSeq: tipSeq + 1, newEntries });
    }
  }

  return { ok: true, perWriter, presentCount };
}
