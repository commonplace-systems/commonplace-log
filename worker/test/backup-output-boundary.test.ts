import { mkdtempSync, cpSync, appendFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

it("D4: reviewed output paths pass; debug manifest, aliased sink and new module fail", () => {
  const root = mkdtempSync(join(tmpdir(), "backup-output-control-"));
  const script = fileURLToPath(new URL("../scripts/check-backup-output.py", import.meta.url));
  const source = fileURLToPath(new URL("../backup/", import.meta.url));
  const run = () => spawnSync("python3", [script, "--backup-dir", root], { encoding: "utf8" });
  try {
    cpSync(source, root, { recursive: true });
    expect(run().status).toBe(0);
    for (const mutation of ['\nconsole.log("manifest", {log_ids: ["fixture-only"]});\n', '\nconst output = console.log; output("fixture-only");\n']) {
      cpSync(source, root, { recursive: true });
      appendFileSync(join(root, "run.ts"), mutation);
      const red = run();
      expect(red.status).toBe(1);
      expect(red.stdout).toContain("An output path may have changed");
      console.info("D4 injected fixture output rejected", red.stdout.trim());
    }
    cpSync(source, root, { recursive: true });
    writeFileSync(join(root, "debug.js"), 'console.log("fixture-only")');
    expect(run().status).toBe(1);
    rmSync(join(root, "debug.js"));
    expect(run().status).toBe(0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
