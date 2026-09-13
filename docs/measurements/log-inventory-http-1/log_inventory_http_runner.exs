ExUnit.start(autorun: false, exclude: [], include: [], trace: false)
Code.require_file(System.fetch_env!("LOG_INVENTORY_HTTP_TEST_FILE"))
result = ExUnit.run()
output = System.fetch_env!("LOG_INVENTORY_HTTP_RESULT_FILE")
File.write!(output, Jason.encode!(result) <> "\n")

System.halt(
  if result.total == 1 and result.failures == 0 and result.excluded == 0 and result.skipped == 0,
    do: 0,
    else: 2
  )
