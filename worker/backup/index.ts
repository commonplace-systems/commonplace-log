import { runBackup, type BackupEnv } from "./run";

// Separate script: no HTTP entrypoint, Container import, or lifecycle configuration.
export default {
  async scheduled(_controller: ScheduledController, env: BackupEnv): Promise<void> {
    const result = await runBackup(env);
    if (result.outcome !== "complete") throw new Error(`backup_stopped:${result.run_id}`);
  },
} satisfies ExportedHandler<BackupEnv>;
