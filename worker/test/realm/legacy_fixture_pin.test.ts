import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

/**
 * LOG-LEGACY-REALM-FIX-1. `fixtures/legacy-76f9028/` holds the realm code that was deployed before
 * 2026-09-13 (log `76f9028112feeba557e4d45060f1cbdead98e7f3`, Worker version `c9515b6d`), copied
 * with `git show 76f9028:worker/src/realm/<file>.ts`. `legacy_realm.workers.test.ts` builds its
 * legacy realm by RUNNING that code.
 *
 * ⭐ THE PIN IS A RECONSTRUCTION, NOT A SHAPE CHECK: each value is the git blob id of that path in
 * the `76f9028` tree (`git rev-parse 76f9028:worker/src/realm/<file>.ts`), and the test recomputes it
 * from the fixture's bytes. One changed byte, or a re-vendored copy from another commit, changes the
 * id. Verify the pinned ids against git with `git rev-parse` rather than trusting this table.
 */
const SOURCE_COMMIT = "76f9028112feeba557e4d45060f1cbdead98e7f3";
const PINNED_BLOBS: Record<string, string> = {
  "http.ts": "7e769bc48f752847424b0b2c330a7ce8469bf0a7",
  "realm_auth.ts": "7ea2f781ab0cacff5b81d057c5ba7d87d4a4036f",
  "registry.ts": "89ddf93c967c3fad764dac6f3960f861c5f6dd02",
  "schema.ts": "2102710cec38d0b3106402f3d5a45dd7997d1880",
  "store.ts": "53a83422f7208f000b6a7f5e47870b24d56a8561",
};

const FIXTURE_DIR = resolve(import.meta.dirname, "fixtures/legacy-76f9028");

function gitBlobId(bytes: Uint8Array): string {
  return createHash("sha1").update(`blob ${bytes.byteLength}\0`).update(bytes).digest("hex");
}

describe(`legacy realm fixture is byte-pinned to ${SOURCE_COMMIT}`, () => {
  test("the blob-id recomputation matches git's own id for a known object", () => {
    // Control for the instrument: git's documented id of the empty blob.
    expect(gitBlobId(new Uint8Array())).toBe("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
  });

  test("the fixture directory holds exactly the pinned files", () => {
    expect(readdirSync(FIXTURE_DIR).sort()).toEqual(Object.keys(PINNED_BLOBS).sort());
  });

  test.each(Object.entries(PINNED_BLOBS))("%s is byte-identical to 76f9028", (name, blob) => {
    expect(gitBlobId(readFileSync(resolve(FIXTURE_DIR, name)))).toBe(blob);
  });
});
