import { describe, expect, it } from "vitest";
import { ERROR_STATUS, envelope, toWireDetails } from "../src/do/errors";

/**
 * SP2 Task 7: the §11.6 error table, envelope constructor, and the
 * camelCase -> snake_case details mapper. Plain-node unit tests — the module
 * is runtime-neutral, and this file pins the ONE spelling site for every
 * error code, including rows the DO can never emit locally (507 storage_full
 * is not simulable in workerd; 401/403 are gateway-side, SP4).
 */

describe("ERROR_STATUS (§11.6 table)", () => {
  it("carries the FULL §11.6 status/code table, exactly", () => {
    expect(ERROR_STATUS).toEqual({
      invalid_json: 400,
      unauthenticated: 401,
      unauthorized: 403,
      log_not_found: 404,
      log_mismatch: 409,
      writer_gap: 409,
      writer_fork: 409,
      entry_id_collision: 409,
      entry_too_large: 413,
      batch_too_large: 413,
      invalid_entry: 422,
      storage_full: 507,
    });
  });

  it("pins the 507 storage_full row (not simulable in local workerd — §15.6)", () => {
    expect(ERROR_STATUS.storage_full).toBe(507);
  });

  it("pins the 409 quadruplet: log_mismatch, writer_gap, writer_fork, entry_id_collision", () => {
    expect(ERROR_STATUS.log_mismatch).toBe(409);
    expect(ERROR_STATUS.writer_gap).toBe(409);
    expect(ERROR_STATUS.writer_fork).toBe(409);
    expect(ERROR_STATUS.entry_id_collision).toBe(409);
  });

  it("pins both 413 codes: entry_too_large and batch_too_large", () => {
    expect(ERROR_STATUS.entry_too_large).toBe(413);
    expect(ERROR_STATUS.batch_too_large).toBe(413);
  });
});

describe("envelope (§11.6 shape)", () => {
  it("builds the exact spec envelope with details", () => {
    expect(
      envelope("writer_gap", "expected writer sequence 28", {
        writer_id: "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
        expected_seq: 28,
        tip_entry_id: "0198cc70-3800-75bd-b56a-5f913fbdeed3",
      }),
    ).toEqual({
      error: {
        code: "writer_gap",
        message: "expected writer sequence 28",
        details: {
          writer_id: "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
          expected_seq: 28,
          tip_entry_id: "0198cc70-3800-75bd-b56a-5f913fbdeed3",
        },
      },
    });
  });

  it("omits the details key entirely when no details are given", () => {
    const built = envelope("invalid_json", "request is not valid JSON");
    expect(built).toEqual({
      error: { code: "invalid_json", message: "request is not valid JSON" },
    });
    expect(Object.hasOwn(built.error, "details")).toBe(false);
  });
});

describe("toWireDetails (StoreError camelCase -> §11.6 snake_case)", () => {
  it("maps the recorded StoreError keys: expectedSeq, tipEntryId, writerId, entryId", () => {
    expect(
      toWireDetails({
        writerId: "w",
        expectedSeq: 28,
        tipEntryId: "t",
        entryId: "e",
      }),
    ).toEqual({
      writer_id: "w",
      expected_seq: 28,
      tip_entry_id: "t",
      entry_id: "e",
    });
  });

  it("leaves already-snake_case and single-word keys untouched (reason, seq, expected_seq)", () => {
    expect(
      toWireDetails({ reason: "body-not-object", seq: 3, expected_seq: 4 }),
    ).toEqual({ reason: "body-not-object", seq: 3, expected_seq: 4 });
  });

  it("preserves null values (tipEntryId null for a fresh writer)", () => {
    expect(toWireDetails({ tipEntryId: null, expectedSeq: 1, writerId: "w" })).toEqual({
      tip_entry_id: null,
      expected_seq: 1,
      writer_id: "w",
    });
  });

  it("passes non-object details through unchanged", () => {
    expect(toWireDetails(undefined)).toBeUndefined();
    expect(toWireDetails(null)).toBeNull();
    expect(toWireDetails("free text")).toBe("free text");
  });

  it("does not mutate its input", () => {
    const input = { expectedSeq: 2, writerId: "w" };
    toWireDetails(input);
    expect(input).toEqual({ expectedSeq: 2, writerId: "w" });
  });
});
