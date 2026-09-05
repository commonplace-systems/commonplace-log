import { readFileSync, readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
describe("backup deployment boundary", () => {
  it("A4: production backup references no realm-write surface; live realm code is the positive control", () => {
    const pattern = /\/(?:create-log|take-lease|commit|realm\/read-capability)|realm_secret|write_secret|storageFetch/g;
    const backup = source("../backup/index.ts") + source("../backup/run.ts");
    const directory = new URL("../src/realm/", import.meta.url);
    const live = readdirSync(directory).filter((p) => p.endsWith(".ts"))
      .map((p) => readFileSync(new URL(p, directory), "utf8")).join("\n");
    expect((live.match(pattern) ?? []).length).toBeGreaterThan(0);
    expect(backup.match(pattern) ?? []).toEqual([]);
    console.info("A4 SOURCE live control matches=%d backup=0", (live.match(pattern) ?? []).length);
  });
  it("production is a second script referencing the existing DO namespace with no HTTP/test/Container entry", () => {
    const config = source("../wrangler.backup.jsonc");
    expect(config).toContain('"name": "commonplace-log-backup"');
    expect(config).toContain('"main": "backup/index.ts"');
    expect(config).toContain('"script_name": "commonplace-log"');
    expect(config).toContain('"class_name": "RealmNode"');
    expect(config).not.toMatch(/"(?:containers|migrations|triggers)"/);
    expect(source("../backup/index.ts")).not.toMatch(/\bfetch\s*\(/);
    expect(source("../backup/index.ts")).not.toContain("test/");
    expect(source("../wrangler.jsonc")).toContain('"containers"');
  });
});
