[out] = System.argv()
out = Path.expand(out)

source_files =
  System.fetch_env!("RESTORE_CLIENT_EMPTY_ENTRIES_COMPILE_SOURCES")
  |> Jason.decode!()
  |> Enum.map(&Path.expand/1)

isolated = Path.join(out, "isolated-ebin")
File.mkdir_p!(isolated)

case Kernel.ParallelCompiler.compile_to_path(source_files, isolated) do
  {:ok, _, _} ->
    :ok

  {:error, errors, warnings} ->
    IO.inspect(errors, file: :stderr, limit: :infinity)
    IO.inspect(warnings, file: :stderr, limit: :infinity)
    System.halt(2)
end

Code.prepend_path(isolated)
ExUnit.start(autorun: false, exclude: [:test], include: [restore_empty_entries: true], trace: false)
Code.require_file(Path.expand(System.fetch_env!("RESTORE_CLIENT_EMPTY_ENTRIES_TEST_FILE")))
result = ExUnit.run()

File.write!(Path.join(out, "app-result.raw.json"), Jason.encode!(result) <> "\n")

summary = %{
  "total" => result.total,
  "failures" => result.failures,
  "excluded" => result.excluded,
  "skipped" => result.skipped,
  "expected_total" => 9,
  "expected_excluded" => 7,
  "expected_failures" => 0,
  "status" => if(result.total == 9 and result.failures == 0 and result.excluded == 7 and result.skipped == 0, do: "expected", else: "mismatch")
}

File.write!(Path.join(out, "app-result.json"), Jason.encode!(summary) <> "\n")

System.halt(
  if result.total == 9 and result.failures == 0 and result.excluded == 7 and result.skipped == 0,
    do: 0,
    else: 2
)
