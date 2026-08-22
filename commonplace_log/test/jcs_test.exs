defmodule Commonplace.Log.JcsTest do
  @moduledoc """
  Conformance harness for the RFC 8785 canonicalizer, driven by the shared
  vector corpus in `conformance/canonical-json/`. The corpus is the arbiter:
  output must be byte-identical to `expected.hex`. Cases named `9xx-*` carry
  deliberately-wrong expected bytes and must MISMATCH (inverted assertion);
  they are excluded from the pass gate.
  """
  use ExUnit.Case, async: true

  @corpus_dir Path.expand("../../conformance/canonical-json", __DIR__)

  case_names =
    @corpus_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@corpus_dir, &1)))
    |> Enum.sort()

  {mismatch_cases, pass_cases} =
    Enum.split_with(case_names, &Regex.match?(~r/^9\d\d-/, &1))

  @pass_cases pass_cases
  @mismatch_cases mismatch_cases

  defp load_case(name) do
    dir = Path.join(@corpus_dir, name)

    # input.json is authoritative as raw bytes; parse those bytes here.
    input = dir |> Path.join("input.json") |> File.read!() |> Jason.decode!()

    # expected.hex is one line of lowercase hex; trailing LF is file formatting.
    expected_hex = dir |> Path.join("expected.hex") |> File.read!() |> String.trim()
    assert expected_hex =~ ~r/^[0-9a-f]+$/

    {input, expected_hex}
  end

  describe "corpus discovery (anti-vacuity)" do
    test "finds at least 18 pass-gate cases" do
      assert length(@pass_cases) >= 18
    end

    test "finds at least one deliberate-mismatch (9xx) case" do
      assert length(@mismatch_cases) >= 1
    end
  end

  describe "canonicalize matches shared vectors" do
    for name <- pass_cases do
      @case_name name
      test @case_name do
        {input, expected_hex} = load_case(@case_name)
        out = Commonplace.Log.Jcs.canonicalize(input)
        assert is_binary(out)
        assert Base.encode16(out, case: :lower) == expected_hex
      end
    end
  end

  describe "deliberate-mismatch (9xx) cases must NOT match correct output" do
    for name <- mismatch_cases do
      @case_name name
      test @case_name do
        {input, expected_hex} = load_case(@case_name)
        out = Commonplace.Log.Jcs.canonicalize(input)
        refute Base.encode16(out, case: :lower) == expected_hex
      end
    end
  end
end
