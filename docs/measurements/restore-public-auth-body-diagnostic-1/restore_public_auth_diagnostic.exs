out = Path.expand(System.fetch_env!("RESTORE_PUBLIC_AUTH_OUT"))
test_file = Path.expand(System.fetch_env!("RESTORE_PUBLIC_AUTH_TEST_FILE"))
app_ebin = Path.expand(System.fetch_env!("RESTORE_PUBLIC_AUTH_APP_EBIN"))
dep_ebin = Path.expand(System.fetch_env!("RESTORE_PUBLIC_AUTH_DEP_EBIN"))
beam_root = Path.expand(System.fetch_env!("RESTORE_PUBLIC_AUTH_BEAM_ROOT"))
expected_case = System.fetch_env!("RESTORE_PUBLIC_AUTH_EXPECTED_CASE")

Path.wildcard(Path.join(beam_root, "*/ebin")) |> Enum.each(&Code.prepend_path/1)
Code.prepend_path(dep_ebin)
Code.prepend_path(app_ebin)

{:module, Commonplace.Log.Persistence.CloudflareSidecar.Httpc} =
  Code.ensure_loaded(Commonplace.Log.Persistence.CloudflareSidecar.Httpc)

httpc_path =
  case :code.which(Commonplace.Log.Persistence.CloudflareSidecar.Httpc) do
    path when is_list(path) -> Path.expand(List.to_string(path))
    path when is_binary(path) -> Path.expand(path)
    other -> raise("CloudflareSidecar.Httpc has no loaded beam: #{inspect(other)}")
  end

unless httpc_path == Path.join(dep_ebin, "Elixir.Commonplace.Log.Persistence.CloudflareSidecar.Httpc.beam") do
  raise("unexpected Httpc beam: #{httpc_path}")
end

for app <- [:crypto, :inets, :ssl] do
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    {:error, reason} -> raise("#{app} start failed: #{inspect(reason)}")
  end
end

source_cases =
  Regex.scan(~r/test\s+"([^"]+)"/, File.read!(test_file), capture: :all_but_first)
  |> List.flatten()
  |> Enum.map(&("test " <> &1))
  |> Enum.sort()

unless source_cases == [expected_case],
  do: raise("fixture case manifest differs: #{inspect(source_cases)}")

ExUnit.start(autorun: false, exclude: [], include: [], trace: false)
Code.require_file(test_file)
result = ExUnit.run()
summary = %{
  "total" => result.total,
  "failures" => result.failures,
  "excluded" => result.excluded,
  "skipped" => result.skipped,
  "expected_total" => 1,
  "expected_failures" => 0,
  "expected_case" => expected_case,
  "httpc_beam" => httpc_path,
  "status" => if(result.total == 1 and result.failures == 0 and result.excluded == 0 and result.skipped == 0, do: "expected", else: "mismatch")
}
File.write!(Path.join(out, "app-result.raw.json"), Jason.encode!(result) <> "\n")
File.write!(Path.join(out, "app-result.json"), Jason.encode!(summary) <> "\n")
System.halt(if(summary["status"] == "expected", do: 0, else: 2))
