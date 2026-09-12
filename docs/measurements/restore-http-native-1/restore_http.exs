ExUnit.start(autorun: false, exclude: [], include: [])
Code.require_file(System.get_env("RESTORE_HTTP_TEST_FILE"))
result = ExUnit.run()
File.write!(System.fetch_env!("RESTORE_HTTP_RESULT_FILE"), Jason.encode!(result) <> "\n")

System.halt(
  if(result.failures == 0 and result.skipped == 0 and result.excluded == 0 and result.total == 1,
    do: 0,
    else: 1
  )
)
