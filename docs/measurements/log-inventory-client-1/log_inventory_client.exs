out = Path.expand(System.fetch_env!("LOG_INVENTORY_CLIENT_OUTPUT"))
ExUnit.start(autorun: false, exclude: [], include: [], trace: false)
Code.require_file(System.fetch_env!("LOG_INVENTORY_CLIENT_TEST_FILE"))
result = ExUnit.run()

File.write!(Path.join(out, "app-result.raw.json"), Jason.encode!(result) <> "\n")

summary = %{
  "total" => result.total,
  "failures" => result.failures,
  "excluded" => result.excluded,
  "skipped" => result.skipped,
  "expected_total" => 8,
  "expected_failures" => 0,
  "status" => if(result.total == 8 and result.failures == 0, do: "expected", else: "mismatch")
}

File.write!(Path.join(out, "app-result.json"), Jason.encode!(summary) <> "\n")
Application.stop(:commonplace_log)

System.halt(
  if result.total == 8 and result.failures == 0 and result.excluded == 0 and result.skipped == 0,
    do: 0,
    else: 2
)
