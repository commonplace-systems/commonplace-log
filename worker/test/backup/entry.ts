import { RealmContainer } from "../../src/realm/container";
import backup from "../../backup/index";
import { runBackup, type BackupEnv } from "../../backup/run";

export { RealmContainer };
// This HTTP trigger and local DO export are absent from the production entry module.
export default {
  ...backup,
  async fetch(request: Request, env: BackupEnv): Promise<Response> {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/run") return new Response(null, { status: 404 });
    const result = await runBackup(env);
    return Response.json(result, { status: result.outcome === "complete" ? 200 : 503 });
  },
};
