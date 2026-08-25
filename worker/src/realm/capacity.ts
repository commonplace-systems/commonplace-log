const CAPACITY_MESSAGE = "Maximum number of running container instances exceeded";

/**
 * Map the platform's at-capacity start failure to 503 `realm_capacity`.
 *
 * Measured on the real platform 2026-08-25: the SDK does NOT throw for this
 * case — `containerFetch` RESOLVES to a 500 Response whose text body carries
 * the message ("Failed to start container: Maximum number of running
 * container instances exceeded …"). The thrown-error arm is kept because the
 * unit test stipulated it, but the Response arm is the one that fires.
 */
export async function containerFetchWithCapacityMapping(
  fetchContainer: () => Promise<Response>,
): Promise<Response> {
  let response: Response;
  try {
    response = await fetchContainer();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes(CAPACITY_MESSAGE)) return capacity();
    throw error;
  }
  if (response.status === 500) {
    const probe = response.clone();
    const text = await probe.text();
    if (text.includes(CAPACITY_MESSAGE)) return capacity();
  }
  return response;
}

function capacity(): Response {
  return Response.json({ ok: false, error: { code: "realm_capacity" } }, { status: 503 });
}
