defmodule Commonplace.Log.AuditTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{Engine, Jcs, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Test.SQLAudit

  @created_at "2026-08-22T12:34:56Z"

  setup do
    root =
      Path.join(System.tmp_dir!(), "commonplace-audit-#{System.unique_integer([:positive])}")

    log_id = UUID.uuidv7()
    {:ok, store} = LocalSQLite.open(root, log_id)
    :ok = LocalSQLite.create_log(store, log_id, %{format_version: 1})

    on_exit(fn ->
      LocalSQLite.close(store)
      File.rm_rf!(root)
    end)

    %{log_id: log_id, store: store}
  end

  test "a legitimately empty audit reports successful reads and zero subjects", %{store: store} do
    assert %{
             observed: [:entries, :writer_tips, :persistence_meta],
             examined: %{writers: 0, entries: 0},
             violations: []
           } = SQLAudit.audit(store)

    SQLAudit.assert_clean_empty(store)
  end

  test "the default clean audit requires subjects", %{log_id: log_id, store: store} do
    writer_id = UUID.uuidv7()
    entry_id = UUID.uuidv7()

    entry = %{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => entry_id,
      "writer_id" => writer_id,
      "writer_seq" => 1,
      "prev_entry_id" => nil,
      "created_at" => @created_at,
      "body" => %{"audit" => true}
    }

    assert {:ok, %{inserted: 1}} =
             Engine.merge(LocalSQLite, store, log_id, [Jcs.canonicalize(entry)])

    assert %{examined: %{writers: 1, entries: 1}, violations: []} = SQLAudit.audit(store)
    SQLAudit.assert_clean(store)
  end
end
