export { CommonplaceLog } from "./commonplace-log-do";

export default {
  async fetch(): Promise<Response> {
    return new Response("commonplace-log", { status: 200 });
  },
} satisfies ExportedHandler;
