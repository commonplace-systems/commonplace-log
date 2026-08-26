# Storage-growth instrument. Appends N entries through DocumentProfile into a
# fresh data directory and prints (entries, main .sqlite3 bytes, -wal bytes)
# at N/4 steps. The point of the N/4 steps: a bounded resource measured over a
# window shorter than its bound reads as a slope. The WAL is such a resource —
# it plateaus at the 1000-page autocheckpoint (~4.1 MB) and is reused, never
# shrunk — so any growth claim needs points PAST where the cap could sit.
#
#   WALDIR=$(mktemp -d) mix run scripts/measure_wal_growth.exs [N] [body_bytes]
#
# Measured 2026-08-26 (N=1000, 1500-byte bodies): see docs/measurements/2026-08-26-wal-growth.md
alias Commonplace.Log.DocumentProfile

Application.put_env(:commonplace_log, Commonplace.LogStore.SQLite,
  data_dir: System.get_env("WALDIR")
)

log_id = Commonplace.Log.UUID.uuidv7()
{:ok, doc} = DocumentProfile.create_log(log_id, [])

sizes = fn n ->
  dir = System.get_env("WALDIR")
  [main] = Path.wildcard(Path.join(dir, log_id <> ".sqlite3"))
  wal = main <> "-wal"
  {n, File.stat!(main).size, if(File.exists?(wal), do: File.stat!(wal).size, else: 0)}
end

{n_total, body_bytes} =
  case System.argv() do
    [a, b] -> {String.to_integer(a), String.to_integer(b)}
    [a] -> {String.to_integer(a), 1500}
    _ -> {1000, 1500}
  end

for n <- 1..n_total do
  body = %{"edit" => String.duplicate("x", body_bytes)}

  {:ok, _} =
    DocumentProfile.append_batch(doc, [body],
      operation_id: "op-#{n}",
      created_at: DateTime.utc_now()
    )

  if rem(n, div(n_total, 4)) == 0, do: IO.inspect(sizes.(n), label: "entries/main/wal")
end
