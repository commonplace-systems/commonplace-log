[out, selected_line] = System.argv()
out = Path.expand(out)
selected_line = String.to_integer(selected_line)
root = Path.expand("../../..", __DIR__)

for path <- [
      System.get_env("RESTORE_BINDING_NATIVE1_APP_EBIN"),
      System.get_env("RESTORE_BINDING_NATIVE1_DEP_EBIN")
    ],
    not is_nil(path) do
  Code.prepend_path(path)
end

{:ok, _started} = Application.ensure_all_started(:commonplace_log)
ExUnit.start(autorun: false, exclude: [], include: [])
ExUnit.configure(include: [line: selected_line])
Code.require_file(Path.join(root, "commonplace_log/test/document_profile_test.exs"))
result = ExUnit.run()
File.write!(Path.join(out, "native-result.raw.json"), Jason.encode!(result))

unless result.total == 1 and result.failures == 0 and result.skipped == 0 and
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
