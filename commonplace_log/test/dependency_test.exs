defmodule Commonplace.Log.DependencyTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)

  test "Engine has no storage-client dependencies, with a positive control" do
    source = File.read!(Path.join(@lib, "commonplace/log/engine.ex"))
    assert source =~ "Engine"

    for forbidden <- ["Exqlite", ":httpc", "Req", "Finch", "Tesla"] do
      refute source =~ forbidden
    end
  end

  test "Sync has no storage-client dependencies, with a positive control" do
    source = File.read!(Path.join(@lib, "commonplace/log/sync.ex"))
    assert source =~ "Sync"

    for forbidden <- ["Exqlite", "LocalSQLite", ":httpc", "Req", "Finch", "Tesla"] do
      refute source =~ forbidden
    end
  end

  test "persistence contract modules contain no domain-semantic dependencies, with a positive control" do
    paths =
      Path.wildcard(Path.join(@lib, "commonplace/log/persistence*.ex")) ++
        Path.wildcard(Path.join(@lib, "commonplace/log/persistence/**/*.ex"))

    assert paths != []
    source = Enum.map_join(paths, "\n", &File.read!/1)
    assert source =~ "Persistence"

    for forbidden <- ["Commonplace.Log.Entry", "Commonplace.Log.Jcs", "Commonplace.Log.MergePlan"] do
      refute source =~ forbidden
    end
  end
end
