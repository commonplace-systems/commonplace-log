# Conformance vector emitter (Elixir side of the cross-runtime byte-diff
# harness, conformance/check.sh).
#
# For every case directory under conformance/canonical-json/ — including the
# deliberately-wrong 9xx cases — read input.json as raw bytes, decode as
# JSON, canonicalize via Commonplace.Log.Jcs, and write the canonical bytes
# to `<outdir>/<case-name>.bin`. The harness diffs these files against the
# TypeScript emitter's output and against the decoded expected.hex bytes;
# this script itself renders no verdict.
#
# Usage: cd commonplace_log && mix run scripts/emit_vectors.exs <outdir>

[out_dir] =
  case System.argv() do
    [dir] -> [dir]
    _ -> raise ArgumentError, "usage: mix run scripts/emit_vectors.exs <outdir>"
  end

corpus_dir = Path.expand("../../conformance/canonical-json", __DIR__)

File.mkdir_p!(out_dir)

cases =
  corpus_dir
  |> File.ls!()
  |> Enum.filter(&File.dir?(Path.join(corpus_dir, &1)))
  |> Enum.sort()

for name <- cases do
  input_bytes = File.read!(Path.join([corpus_dir, name, "input.json"]))
  value = Jason.decode!(input_bytes)
  bytes = Commonplace.Log.Jcs.canonicalize(value)
  File.write!(Path.join(out_dir, name <> ".bin"), bytes)
end

IO.puts(:stderr, "emit_vectors.exs: emitted #{length(cases)} cases to #{out_dir}")
