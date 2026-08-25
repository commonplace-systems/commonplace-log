defmodule Commonplace.Log.EntryTest do
  @moduledoc """
  Conformance harness for the version-1/version-2 entry validator, driven by the shared
  corpus. `conformance/invalid-entries/` cases must each produce exactly the
  error code (line 1 of `error.txt`) and reason slug (line 2); the valid-entry
  anchors are `conformance/canonical-json/016` (accept, exact canonical
  bytes), `017` (>1 MiB raw input, small canonical form — the §7.1 cap is on
  canonical bytes), and `018` (float-spelled integer fields, byte-identical
  canonical form to 016), `019` (v2 with operation_id), and `020` (v2 without
  operation_id, with float-spelled 2.0).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Log.Entry

  @invalid_dir Path.expand("../../conformance/invalid-entries", __DIR__)
  @canonical_dir Path.expand("../../conformance/canonical-json", __DIR__)

  invalid_cases =
    @invalid_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@invalid_dir, &1)))
    # 9xx cases are reserved for deliberately-wrong vectors (the Task 8
    # harness red-demonstration); none exist in invalid-entries yet, but
    # exclude them from the pass gate now so adding one cannot silently
    # join it.
    |> Enum.reject(&Regex.match?(~r/^9\d\d-/, &1))
    |> Enum.sort()

  @invalid_cases invalid_cases

  defp read_expected_bytes(case_name) do
    @canonical_dir
    |> Path.join(case_name)
    |> Path.join("expected.hex")
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  defp read_input(dir, case_name) do
    dir |> Path.join(case_name) |> Path.join("input.json") |> File.read!()
  end

  describe "corpus discovery (anti-vacuity)" do
    test "finds at least 35 invalid-entries cases" do
      assert length(@invalid_cases) >= 35
    end
  end

  describe "invalid-entries corpus: exact code and reason" do
    for name <- invalid_cases do
      @case_name name
      test @case_name do
        raw = read_input(@invalid_dir, @case_name)

        [code, reason] =
          @invalid_dir
          |> Path.join(@case_name)
          |> Path.join("error.txt")
          |> File.read!()
          |> String.split("\n", trim: true)

        assert Entry.validate_entry(raw) == {:error, code, reason}
      end
    end
  end

  describe "valid-entry anchors from canonical-json" do
    test "016-spec-example-entry validates ok with exactly its expected bytes" do
      raw = read_input(@canonical_dir, "016-spec-example-entry")
      expected = read_expected_bytes("016-spec-example-entry")
      assert Entry.validate_entry(raw) == {:ok, expected}
    end

    test "017-whitespace-padded-entry (>1 MiB raw) validates ok — cap is on canonical bytes" do
      raw = read_input(@canonical_dir, "017-whitespace-padded-entry")
      # Cap-side premise: the raw input really is over the 1 MiB cap, so a
      # validator measuring raw bytes would wrongly reject this case.
      assert byte_size(raw) > 1_048_576
      expected = read_expected_bytes("017-whitespace-padded-entry")
      assert Entry.validate_entry(raw) == {:ok, expected}
    end

    test "018-float-spelled-integers validates ok, byte-identical to 016" do
      raw = read_input(@canonical_dir, "018-float-spelled-integers")
      expected = read_expected_bytes("018-float-spelled-integers")
      assert expected == read_expected_bytes("016-spec-example-entry")
      assert Entry.validate_entry(raw) == {:ok, expected}
    end

    for name <- ["019-entry-v2-operation-id", "020-entry-v2-without-operation-id"] do
      @case_name name
      test "#{name} validates ok with exactly its expected bytes" do
        raw = read_input(@canonical_dir, @case_name)
        expected = read_expected_bytes(@case_name)
        assert Entry.validate_entry(raw) == {:ok, expected}
      end
    end
  end

  describe "version-2 operation_id boundary and parsed-number semantics" do
    defp mutate_v2(fun) do
      @canonical_dir
      |> read_input("020-entry-v2-without-operation-id")
      |> Jason.decode!()
      |> then(fun)
      |> Jason.encode!()
    end

    test "accepts a non-empty operation_id of exactly 256 UTF-8 bytes" do
      raw = mutate_v2(&Map.put(&1, "operation_id", String.duplicate("é", 128)))
      assert {:ok, _canonical} = Entry.validate_entry(raw)
    end

    test "rejects string version 2 while JSON 2.0 is accepted by case 020" do
      raw = mutate_v2(&Map.put(&1, "version", "2"))
      assert Entry.validate_entry(raw) == {:error, "invalid_entry", "wrong-version"}
    end
  end

  describe "LOCAL regression gates (non-corpus): Jason DecodeError classifier branches" do
    # These pin the classifier branches in Commonplace.Log.Entry that the
    # corpus does not reach (024 covers only the lone HIGH surrogate at
    # string end). They are local to this runtime — NOT cross-runtime
    # contract — and exist so each classifier branch has been seen to fire.
    # A Jason upgrade that changes DecodeError shapes (token/position) turns
    # these red together with corpus cases 023/024; that means the
    # classifier needs re-probing, not that the corpus is wrong.

    defp entry_with_body_string(escaped) do
      ~s({"version": 1,) <>
        ~s( "log_id": "0198cc6e-47ac-7d72-93db-b6fbd92bfca2",) <>
        ~s( "entry_id": "0198cc70-3800-75bd-b56a-5f913fbdeed3",) <>
        ~s( "writer_id": "fab4e8a5-ce9e-48d0-8f78-1d312b978207",) <>
        ~s( "writer_seq": 27,) <>
        ~s( "prev_entry_id": "0198cc6f-f11c-7803-aa25-401bc5f781c0",) <>
        ~s( "created_at": "2026-08-21T20:14:03.291Z",) <>
        ~s( "body": {"s": "#{escaped}"}})
    end

    test ~S(lone LOW surrogate "\udc00" — token branch, single-escape shape) do
      # Jason fails with token: "\\udc00" (the escape itself), unlike the
      # lone high surrogate, which fails with token: nil.
      raw = entry_with_body_string(~S(\udc00))
      assert Entry.validate_entry(raw) == {:error, "invalid_entry", "ill-formed-unicode"}
    end

    test ~S(double high surrogate "\ud800\ud800" — token branch, escape-run shape) do
      # Jason fails with the full escape run as the token.
      raw = entry_with_body_string(~S(\ud800\ud800))
      assert Entry.validate_entry(raw) == {:error, "invalid_entry", "ill-formed-unicode"}
    end

    test ~S(high surrogate before non-escape "\ud800x" — position-lookback branch) do
      # Jason fails with token: nil and position one byte past the 6-byte
      # escape; the classifier looks back at raw[position-6, 6]. Probed:
      # this input hits the lookback branch, not the token branch.
      raw = entry_with_body_string(~S(\ud800x))
      assert Entry.validate_entry(raw) == {:error, "invalid_entry", "ill-formed-unicode"}
    end
  end
end
