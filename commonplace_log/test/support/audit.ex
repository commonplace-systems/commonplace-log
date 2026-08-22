defmodule Commonplace.Log.Test.SQLAudit do
  @moduledoc false

  alias Commonplace.Log.Persistence.LocalSQLite
  alias Exqlite.Sqlite3

  @projection_fields ~w(entry_id writer_id writer_seq prev_entry_id created_at)

  @doc "Re-derive the persisted log invariants directly from its SQL rows."
  def audit(%LocalSQLite{conn: conn}) do
    entries =
      query!(
        conn,
        "SELECT entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json " <>
          "FROM entries ORDER BY writer_id, writer_seq"
      )

    tips =
      conn
      |> query!("SELECT writer_id, last_seq, last_entry_id FROM writer_tips")
      |> Map.new(fn [writer_id, last_seq, last_entry_id] ->
        {writer_id, %{last_seq: last_seq, last_entry_id: last_entry_id}}
      end)

    entries_by_writer = Enum.group_by(entries, &Enum.at(&1, 1))
    writers = (Map.keys(entries_by_writer) ++ Map.keys(tips)) |> Enum.uniq() |> Enum.sort()

    writer_violations =
      Enum.flat_map(writers, fn writer_id ->
        audit_writer(writer_id, Map.get(entries_by_writer, writer_id, []), tips[writer_id])
      end)

    revision_violations =
      case query!(conn, "SELECT revision FROM persistence_meta WHERE singleton = 1") do
        [[revision]] when is_integer(revision) and revision >= 0 ->
          []

        rows ->
          [violation("revision-non-negative-integer", :persistence_meta, %{rows: rows})]
      end

    writer_violations ++ revision_violations
  end

  defp audit_writer(writer_id, rows, tip) do
    sequences = Enum.map(rows, &Enum.at(&1, 2))
    count = length(rows)
    max_seq = if sequences == [], do: nil, else: Enum.max(sequences)
    min_seq = if sequences == [], do: nil, else: Enum.min(sequences)
    tip_seq = tip && tip.last_seq

    equality_violations =
      []
      |> add_if(count != max_seq, "writer-count-max", writer_id, %{count: count, max_seq: max_seq})
      |> add_if(count != tip_seq, "writer-count-tip", writer_id, %{count: count, tip_seq: tip_seq})
      |> add_if(max_seq != tip_seq, "writer-max-tip", writer_id, %{
        max_seq: max_seq,
        tip_seq: tip_seq
      })
      |> add_if(min_seq != 1, "writer-min-seq", writer_id, %{min_seq: min_seq})

    tip_id_violations =
      case {tip, Enum.find(rows, &(Enum.at(&1, 2) == tip_seq))} do
        {%{last_entry_id: last_entry_id}, [entry_id | _]} when entry_id == last_entry_id ->
          []

        {%{last_entry_id: last_entry_id}, row} ->
          [
            violation("tip-entry-id", writer_id, %{
              tip_seq: tip_seq,
              tip_entry_id: last_entry_id,
              stored_entry_id: row && hd(row)
            })
          ]

        {nil, _row} ->
          [violation("tip-entry-id", writer_id, %{tip: nil})]
      end

    equality_violations ++ tip_id_violations ++ audit_chain(writer_id, rows) ++ audit_rows(rows)
  end

  defp audit_chain(writer_id, rows) do
    rows
    |> Enum.reduce({[], nil, nil}, fn row, {violations, previous_seq, previous_id} ->
      [entry_id, ^writer_id, writer_seq, prev_entry_id | _] = row

      expected_prev = if writer_seq == 1, do: nil, else: previous_id
      expected_seq = if is_nil(previous_seq), do: 1, else: previous_seq + 1

      violation =
        if writer_seq == expected_seq and prev_entry_id == expected_prev do
          []
        else
          [
            violation("predecessor-chain", {writer_id, writer_seq}, %{
              expected_seq: expected_seq,
              expected_prev_entry_id: expected_prev,
              actual_prev_entry_id: prev_entry_id
            })
          ]
        end

      {violations ++ violation, writer_seq, entry_id}
    end)
    |> elem(0)
  end

  defp audit_rows(rows) do
    Enum.flat_map(rows, fn [entry_id, writer_id, writer_seq, prev_entry_id, created_at, bytes] ->
      coordinate = {writer_id, writer_seq}
      projected = [entry_id, writer_id, writer_seq, prev_entry_id, created_at]

      case Jason.decode(bytes) do
        {:ok, decoded} when is_map(decoded) ->
          embedded = Enum.map(@projection_fields, &Map.get(decoded, &1, :missing))

          if embedded == projected do
            []
          else
            mismatches =
              @projection_fields
              |> Enum.zip(projected)
              |> Enum.zip(embedded)
              |> Enum.flat_map(fn {{field, column_value}, json_value} ->
                if column_value == json_value,
                  do: [],
                  else: [%{field: field, column: column_value, canonical_json: json_value}]
              end)

            [violation("projection-columns", coordinate, %{mismatches: mismatches})]
          end

        {:ok, decoded} ->
          [violation("projection-columns", coordinate, %{canonical_json: decoded})]

        {:error, reason} ->
          [violation("projection-columns", coordinate, %{decode_error: inspect(reason)})]
      end
    end)
  end

  defp add_if(violations, false, _rule, _subject, _details), do: violations

  defp add_if(violations, true, rule, subject, details),
    do: violations ++ [violation(rule, subject, details)]

  defp violation(rule, {writer_id, writer_seq}, details),
    do: %{rule: rule, writer_id: writer_id, coordinate: {writer_id, writer_seq}, details: details}

  defp violation(rule, writer_id, details) when is_binary(writer_id),
    do: %{rule: rule, writer_id: writer_id, details: details}

  defp violation(rule, coordinate, details),
    do: %{rule: rule, coordinate: coordinate, details: details}

  defp query!(conn, sql) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end
end
