[out, selected_line, selected_name] = System.argv()
out = Path.expand(out)
selected_line = String.to_integer(selected_line)
root = Path.expand("../../..", __DIR__)

beam_root = System.get_env("RESTORE_BINDING_BEAM_ROOT")

if beam_root do
  Path.wildcard(Path.join(beam_root, "*/ebin"))
  |> Enum.sort()
  |> Enum.each(&Code.prepend_path/1)
end

Code.prepend_path(System.fetch_env!("RESTORE_BINDING_NATIVE1_DEP_EBIN"))
Code.prepend_path(System.fetch_env!("RESTORE_BINDING_NATIVE1_APP_EBIN"))

{:ok, _started} = Application.ensure_all_started(:commonplace_log)
ExUnit.start(autorun: false, exclude: [], include: [])
ExUnit.configure(exclude: [:test], include: [test: selected_name])
Code.require_file(Path.join(root, "commonplace_log/test/document_profile_test.exs"))
result = ExUnit.run()
File.write!(Path.join(out, "native-result.raw.json"), Jason.encode!(result))

unless result.total == 23 and result.failures == 0 and result.skipped == 0 and
         result.excluded == 22,
       do: raise("continuation did not select exactly one existing test")

File.write!(
  Path.join(out, "native-result.json"),
  Jason.encode!(%{
    "status" => "pass",
    "cases" => [
      "test restore rejects multiwriter and wrong-frontier requests before creating a target"
    ],
    "selected_line" => selected_line,
    "total" => result.total,
    "failures" => result.failures,
    "skipped" => result.skipped,
    "excluded" => result.excluded
  })
)
