defmodule CommonplaceLogTest do
  use ExUnit.Case
  doctest CommonplaceLog

  test "greets the world" do
    assert CommonplaceLog.hello() == :world
  end
end
