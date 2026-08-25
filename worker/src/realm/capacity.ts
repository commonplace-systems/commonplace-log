const CAPACITY_MESSAGE = "Maximum number of running container instances exceeded";

export async function containerFetchWithCapacityMapping(
  fetchContainer: () => Promise<Response>,
): Promise<Response> {
  try {
    return await fetchContainer();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes(CAPACITY_MESSAGE)) {
      return Response.json({ ok: false, error: { code: "realm_capacity" } }, { status: 503 });
    }
    throw error;
  }
}
