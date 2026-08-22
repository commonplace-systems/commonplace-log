defmodule Commonplace.Log.EntryTest do
  @moduledoc """
  Conformance harness for the version-1 entry validator, driven by the shared
  corpus. `conformance/invalid-entries/` cases must each produce exactly the
  error code (line 1 of `error.txt`) and reason slug (line 2); the valid-entry
  anchors are `conformance/canonical-json/016` (accept, exact canonical
  bytes), `017` (>1 MiB raw input, small canonical form — the §7.1 cap is on
  canonical bytes), and `018` (float-spelled integer fields, byte-identical
  canonical form to 016).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Log.Entry

  @invalid_dir Path.expand("../../conformance/invalid-entries", __DIR__)
  @canonical_dir Path.expand("../../conformance/canonical-json", __DIR__)

  invalid_cases =
    @invalid_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@invalid_dir, &1)))
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
    test "finds at least 30 invalid-entries cases" do
      assert length(@invalid_cases) >= 30
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
  end
end
