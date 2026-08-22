/**
 * Table-driven tests for the pure merge classifier (spec §9.3 rules 1–6 and
 * the three merge error codes, §6.3 entry-ID collision, §8 invariants
 * 3/4/9/10). The module under test is pure — no database, no I/O — so this
 * suite runs in the plain-node unit project.
 */
import { describe, expect, it } from "vitest";
import {
  planMerge,
  type BatchEntry,
  type MergeOutcome,
  type TipInfo,
} from "../src/do/merge-plan";

// --- fixtures --------------------------------------------------------------

const encoder = new TextEncoder();

/**
 * Deterministic entry maker: the fake canonical bytes encode every argument,
 * so two calls with identical arguments are byte-equal and any argument
 * difference (including payload alone, for collision/fork rows) changes the
 * bytes. IDs are opaque strings to the classifier; no need for real UUIDs.
 */
function mk(
  writerId: string,
  writerSeq: number,
  entryId: string,
  prevEntryId: string | null,
  payload = "",
): BatchEntry {
  return {
    entryId,
    writerId,
    writerSeq,
    prevEntryId,
    canonicalBytes: encoder.encode(
      `${writerId}/${writerSeq}/${entryId}/${prevEntryId}/${payload}`,
    ),
  };
}

/** Store state for a row: entries already present, tips derived from them. */
function storeOf(present: BatchEntry[]): {
  existing: Map<string, TipInfo>;
  presentByCoord: (w: string, s: number) => Uint8Array | null;
  presentById: (
    id: string,
  ) => { writerId: string; writerSeq: number; bytes: Uint8Array } | null;
} {
  const existing = new Map<string, TipInfo>();
  for (const e of present) {
    const tip = existing.get(e.writerId);
    if (!tip || e.writerSeq > tip.seq) {
      existing.set(e.writerId, { seq: e.writerSeq, entryId: e.entryId });
    }
  }
  return {
    existing,
    presentByCoord: (w, s) =>
      present.find((e) => e.writerId === w && e.writerSeq === s)
        ?.canonicalBytes ?? null,
    presentById: (id) => {
      const e = present.find((p) => p.entryId === id);
      return e
        ? {
            writerId: e.writerId,
            writerSeq: e.writerSeq,
            bytes: e.canonicalBytes,
          }
        : null;
    },
  };
}

// Writer W with three committed entries; the standard "existing store" for
// most rows. Writer ids chosen so sort order is obvious in multi-writer rows.
const W = "writer-mmm";
const w1 = mk(W, 1, "id-w1", null);
const w2 = mk(W, 2, "id-w2", "id-w1");
const w3 = mk(W, 3, "id-w3", "id-w2");

// --- the table -------------------------------------------------------------

interface Row {
  name: string;
  present: BatchEntry[];
  batch: BatchEntry[];
  /** Partial structural match against the outcome (arrays match by length). */
  expected: Record<string, unknown>;
}

const rows: Row[] = [
  {
    name: "empty batch is ok with zero plans (§9.3 vacuous case)",
    present: [w1, w2],
    batch: [],
    expected: { ok: true, perWriter: [], presentCount: 0 },
  },
  {
    name: "fresh writer starting at seq 1 with chained prevs (§9.3 rules 3–5)",
    present: [],
    batch: [mk("wf", 1, "f1", null), mk("wf", 2, "f2", "f1")],
    expected: {
      ok: true,
      presentCount: 0,
      perWriter: [
        {
          writerId: "wf",
          firstNewSeq: 1,
          newEntries: [{ entryId: "f1" }, { entryId: "f2" }],
        },
      ],
    },
  },
  {
    name: "fresh writer NOT starting at 1 → writer_gap with expectedSeq 1 and null tip",
    present: [],
    batch: [mk("wf", 2, "f2", "f1")],
    expected: {
      ok: false,
      code: "writer_gap",
      details: { writerId: "wf", expectedSeq: 1, tipEntryId: null },
    },
  },
  {
    name: "extension at tip+1 naming the tip in prev_entry_id (§9.3 rules 3–4)",
    present: [w1, w2],
    batch: [mk(W, 3, "id-w3", "id-w2")],
    expected: {
      ok: true,
      presentCount: 0,
      perWriter: [
        { writerId: W, firstNewSeq: 3, newEntries: [{ entryId: "id-w3" }] },
      ],
    },
  },
  {
    name: "extension at tip+1 with wrong prev_entry_id → writer_fork (§9.3 rule 4: coordinate holds a different chain)",
    present: [w1, w2],
    batch: [mk(W, 3, "id-x3", "id-w1")],
    expected: {
      ok: false,
      code: "writer_fork",
      details: { writerId: W, seq: 3 },
    },
  },
  {
    name: "batch wholly at/below tip and byte-equal → all present, no plan (§9.3 rule 2, invariant 9)",
    present: [w1, w2, w3],
    batch: [w1, w2, w3],
    expected: { ok: true, perWriter: [], presentCount: 3 },
  },
  {
    name: "partially duplicate batch: present prefix counted, new suffix planned",
    present: [w1, w2],
    batch: [w2, mk(W, 3, "id-w3", "id-w2")],
    expected: {
      ok: true,
      presentCount: 1,
      perWriter: [
        { writerId: W, firstNewSeq: 3, newEntries: [{ entryId: "id-w3" }] },
      ],
    },
  },
  {
    name: "first new entry beyond tip+1 → writer_gap carrying the receiver's tip (§9.3 error 1, §15.5)",
    present: [w1, w2],
    batch: [mk(W, 4, "id-w4", "id-w3")],
    expected: {
      ok: false,
      code: "writer_gap",
      details: { writerId: W, expectedSeq: 3, tipEntryId: "id-w2" },
    },
  },
  {
    name: "different bytes at an occupied coordinate → writer_fork (§9.3 error 2)",
    present: [w1, w2],
    batch: [mk(W, 2, "id-x2", "id-w1", "divergent")],
    expected: {
      ok: false,
      code: "writer_fork",
      details: { writerId: W, seq: 2 },
    },
  },
  {
    name: "existing entry_id with different canonical bytes → entry_id_collision (§9.3 error 3, §6.3)",
    present: [w1, w2],
    // A structurally valid extension that reuses id-w1 for different bytes.
    batch: [mk(W, 3, "id-w1", "id-w2", "reused-id")],
    expected: {
      ok: false,
      code: "entry_id_collision",
      details: { entryId: "id-w1" },
    },
  },
  {
    name: "same entry_id at the SAME coordinate with different bytes → entry_id_collision, not fork (§6.3 MUST)",
    present: [w1, w2],
    // Same id, same (writer, seq) as the stored w2, but tampered bytes.
    // Kills the mutant that drops the byte-equality clause from the
    // stored-id check: without it this row degrades to writer_fork.
    batch: [mk(W, 2, "id-w2", "id-w1", "tampered")],
    expected: {
      ok: false,
      code: "entry_id_collision",
      details: { entryId: "id-w2" },
    },
  },
  {
    name: "same entry_id, same bytes, same coordinate → duplicate, present, NOT a collision (§9.3 rule 2)",
    present: [w1, w2],
    batch: [mk(W, 2, "id-w2", "id-w1")],
    expected: { ok: true, perWriter: [], presentCount: 1 },
  },
  {
    name: "intra-batch sequence hole after a valid first new entry → writer_gap at the hole (§9.3 rule 5)",
    present: [w1, w2],
    batch: [
      mk(W, 3, "id-w3", "id-w2"),
      mk(W, 4, "id-w4", "id-w3"),
      mk(W, 6, "id-w6", "id-w5"),
    ],
    expected: {
      ok: false,
      code: "writer_gap",
      details: { writerId: W, expectedSeq: 5, tipEntryId: "id-w2" },
    },
  },
  {
    name: "intra-batch prev_entry_id not naming the preceding batch entry → invalid_batch (§9.3 rule 5)",
    present: [w1, w2],
    batch: [mk(W, 3, "id-w3", "id-w2"), mk(W, 4, "id-w4", "id-BOGUS")],
    expected: { ok: false, code: "invalid_batch" },
  },
  {
    name: "intra-batch entry_id reused at different coordinates → entry_id_collision (§6.3)",
    present: [],
    batch: [mk("wf", 1, "f-dup", null), mk("wf", 2, "f-dup", "f-dup")],
    expected: {
      ok: false,
      code: "entry_id_collision",
      details: { entryId: "f-dup" },
    },
  },
  {
    name: "intra-batch duplicate coordinate with different bytes → writer_fork",
    present: [],
    batch: [mk("wf", 1, "f1", null), mk("wf", 1, "f1b", null)],
    expected: {
      ok: false,
      code: "writer_fork",
      details: { writerId: "wf", seq: 1 },
    },
  },
  {
    name: "exact duplicate entry within one batch → deduplicated, copy counted as present",
    present: [],
    batch: [mk("wf", 1, "f1", null), mk("wf", 1, "f1", null)],
    expected: {
      ok: true,
      presentCount: 1,
      perWriter: [
        { writerId: "wf", firstNewSeq: 1, newEntries: [{ entryId: "f1" }] },
      ],
    },
  },
  {
    name: "multi-writer batch where one writer fails → whole batch fails with that writer's error, no partial plan",
    present: [w1, w2],
    batch: [
      // "aaa" sorts before W and is entirely valid; the classifier must
      // still refuse the whole batch for W's gap. ok:false carries no
      // perWriter, so no partial plan can escape (§8 invariant 10).
      mk("aaa", 1, "a1", null),
      mk(W, 4, "id-w4", "id-w3"),
    ],
    expected: {
      ok: false,
      code: "writer_gap",
      details: { writerId: W, expectedSeq: 3, tipEntryId: "id-w2" },
    },
  },
  {
    name: "multi-writer all-valid batch → one plan per writer, sorted by writerId",
    present: [w1, w2],
    batch: [
      // Deliberately fed in reverse writer order.
      mk("zzz", 1, "z1", null),
      mk(W, 3, "id-w3", "id-w2"),
      mk("aaa", 1, "a1", null),
      mk("aaa", 2, "a2", "a1"),
    ],
    expected: {
      ok: true,
      presentCount: 0,
      perWriter: [
        {
          writerId: "aaa",
          firstNewSeq: 1,
          newEntries: [{ entryId: "a1" }, { entryId: "a2" }],
        },
        { writerId: W, firstNewSeq: 3, newEntries: [{ entryId: "id-w3" }] },
        { writerId: "zzz", firstNewSeq: 1, newEntries: [{ entryId: "z1" }] },
      ],
    },
  },
];

// --- runner ----------------------------------------------------------------

describe("planMerge classifies batches per spec §9.3", () => {
  it("anti-vacuity: the table has at least 14 rows", () => {
    expect(rows.length).toBeGreaterThanOrEqual(14);
  });

  it.for(rows)("$name", (row) => {
    const { existing, presentByCoord, presentById } = storeOf(row.present);
    const outcome: MergeOutcome = planMerge(
      row.batch,
      existing,
      presentByCoord,
      presentById,
    );
    expect(outcome).toMatchObject(row.expected);
  });

  it("batch order does not matter: shuffled input classifies identically (§9.3 rule 1)", () => {
    const batch = [
      mk(W, 3, "id-w3", "id-w2"),
      mk(W, 4, "id-w4", "id-w3"),
      mk(W, 5, "id-w5", "id-w4"),
    ];
    const shuffled = [batch[2]!, batch[0]!, batch[1]!];
    const { existing, presentByCoord, presentById } = storeOf([w1, w2]);
    const a = planMerge(batch, existing, presentByCoord, presentById);
    const b = planMerge(shuffled, existing, presentByCoord, presentById);
    expect(b).toEqual(a);
    expect(a).toMatchObject({
      ok: true,
      perWriter: [{ writerId: W, firstNewSeq: 3 }],
    });
  });
});
