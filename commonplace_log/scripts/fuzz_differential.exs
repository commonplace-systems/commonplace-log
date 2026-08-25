# Differential fuzz generator (Elixir side of conformance/fuzz.sh).
#
# Generates N pseudo-random I-JSON values with StreamData and writes, per
# case `fuzz-NNNN`:
#
#   <outdir>/fuzz-NNNN.json  the input, as the ELIXIR canonicalizer's bytes
#                            for the generated value — so every input file is
#                            itself canonical by construction, making each
#                            case a fixpoint test as well as a cross-runtime
#                            test (no trailing newline: the file IS the
#                            canonical bytes, exactly);
#   <outdir>/fuzz-NNNN.bin   Elixir's canonical bytes for the value obtained
#                            by RE-PARSING fuzz-NNNN.json with Jason — i.e.
#                            canonicalize(decode(canonicalize(value))), so a
#                            .bin that differs from its .json is a broken
#                            decode∘canonicalize fixpoint in Elixir.
#
# Also writes <outdir>/SEED (one line) so the orchestrator can report it.
# The seed is ALWAYS printed, given or generated; any run is reproduced by
# passing the same <n> and that seed back:
#
#   mix run scripts/fuzz_differential.exs <outdir> <n> [seed]
#
# Value domain (mirrors the SELECTOR in conformance/README.md, "Differential
# fuzz"): null/true/false; integers only within ±(2^53−1); finite doubles
# from uniformly random 64-bit patterns (subnormals and extremes arise
# naturally; non-finite patterns fail the ::float match and are filtered);
# well-formed-Unicode strings incl. controls, quotes, backslashes and astral
# chars; every fifth top-level value is a valid v2 entry (alternating with and
# without operation_id); object keys mixing BMP >= U+E000 with astral chars to stress
# UTF-16-vs-code-point key ordering; arrays/objects nested to depth ~6.
# Deliberately NOT generated (recorded-unpinned classes): integers beyond
# ±(2^53−1), lone surrogates, duplicate keys.
#
# This script renders no verdict; conformance/fuzz.sh diffs the files.

alias Commonplace.Log.Jcs
alias StreamData, as: SD

{out_dir, n, seed} =
  case System.argv() do
    [out_dir, n] ->
      {out_dir, String.to_integer(n), :rand.uniform(2 ** 32) - 1}

    [out_dir, n, seed] ->
      {out_dir, String.to_integer(n), String.to_integer(seed)}

    _ ->
      raise ArgumentError, "usage: mix run scripts/fuzz_differential.exs <outdir> <n> [seed]"
  end

max_safe = 2 ** 53 - 1

# Integers: small (size-scaled) and uniform across the full safe range.
int_gen = SD.one_of([SD.integer(), SD.integer(-max_safe..max_safe)])

# Finite doubles from uniformly random 64-bit patterns. The ::float-64 match
# fails on NaN/Infinity bit patterns (exponent all-ones), which filters
# non-finite values naturally; everything else — subnormals, extremes,
# negative zero — passes through untouched.
float_gen =
  SD.tuple({SD.integer(0..0xFFFFFFFF), SD.integer(0..0xFFFFFFFF)})
  |> SD.map(fn {hi, lo} ->
    case <<hi::32, lo::32>> do
      <<f::float-64>> -> f
      _ -> :nonfinite
    end
  end)
  |> SD.filter(&is_float/1)

# Well-formed Unicode scalar values only — surrogates D800..DFFF are
# excluded by construction (the recorded-unpinned lone-surrogate class).
codepoint_gen =
  SD.frequency([
    {5, SD.integer(0x20..0x7E)},
    {2, SD.member_of([?", ?\\, ?/, 0x08, 0x09, 0x0A, 0x0C, 0x0D])},
    {1, SD.integer(0x00..0x1F)},
    {2, SD.integer(0x80..0xD7FF)},
    {2, SD.integer(0xE000..0xFFFF)},
    {2, SD.integer(0x10000..0x10FFFF)}
  ])

string_gen =
  SD.map(SD.list_of(codepoint_gen, max_length: 12), &List.to_string/1)

# Keys that stress UTF-16 code-unit ordering: astral chars (surrogate pairs,
# leading unit D800..DBFF) must sort BEFORE BMP chars in U+E000..U+FFFF —
# code-point order and UTF-8 byte order both get this wrong.
stress_key_gen =
  SD.map(
    SD.list_of(
      SD.one_of([SD.integer(0xE000..0xFFFF), SD.integer(0x10000..0x10FFFF)]),
      min_length: 1,
      max_length: 3
    ),
    &List.to_string/1
  )

key_gen = SD.frequency([{3, string_gen}, {2, stress_key_gen}])

leaf_gen =
  SD.frequency([
    {1, SD.constant(nil)},
    {1, SD.boolean()},
    {2, int_gen},
    {2, float_gen},
    {2, string_gen}
  ])

# Nesting to depth ~6: each level is a leaf or a composite whose children
# come from the previous level. Duplicate keys are impossible: values are
# Elixir maps.
value_gen =
  Enum.reduce(1..6, leaf_gen, fn _depth, child ->
    SD.frequency([
      {3, leaf_gen},
      {1, SD.list_of(child, max_length: 4)},
      {1, SD.map_of(key_gen, child, max_length: 4)}
    ])
  end)

# Bias the top level toward composites so most cases are structural; cap the
# ambient StreamData size (check_all grows it by 1 per run) so case
# complexity plateaus instead of growing for thousands of runs.
top_gen =
  SD.frequency([
    {2, SD.list_of(value_gen, max_length: 4)},
    {2, SD.map_of(key_gen, value_gen, max_length: 6)},
    {1, value_gen}
  ])
  |> SD.scale(fn size -> min(size, 60) end)

File.mkdir_p!(out_dir)
File.write!(Path.join(out_dir, "SEED"), Integer.to_string(seed) <> "\n")
IO.puts("fuzz_differential.exs: N=#{n} SEED=#{seed}")

counter = :counters.new(3, [])

{:ok, %{}} =
  SD.check_all(top_gen, [initial_seed: {0, 0, seed}, max_runs: n], fn generated_value ->
    :counters.add(counter, 1, 1)
    i = :counters.get(counter, 1)
    name = "fuzz-" <> String.pad_leading(Integer.to_string(i), 4, "0")

    # Deterministically reserve every fifth case for the newly versioned entry
    # shape, while retaining random nested content in its body. Multiples of
    # ten carry operation_id; the alternating fifths omit it. This guarantees
    # both optional-field arms are hit for every allowed N (N >= 100).
    value =
      if rem(i, 5) == 0 do
        :counters.add(counter, 2, 1)

        entry = %{
          "version" => 2,
          "log_id" => "0198cc6e-47ac-7d72-93db-b6fbd92bfca2",
          "entry_id" => "0198cc70-3800-75bd-b56a-5f913fbdeed3",
          "writer_id" => "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
          "writer_seq" => 1,
          "prev_entry_id" => nil,
          "created_at" => "2026-08-25T19:15:00Z",
          "body" => %{"fuzz_value" => generated_value}
        }

        if rem(i, 10) == 0 do
          :counters.add(counter, 3, 1)
          Map.put(entry, "operation_id", "fuzz-operation-#{i}")
        else
          entry
        end
      else
        generated_value
      end

    json = Jcs.canonicalize(value)
    File.write!(Path.join(out_dir, name <> ".json"), json)

    bin = json |> Jason.decode!() |> Jcs.canonicalize()
    File.write!(Path.join(out_dir, name <> ".bin"), bin)

    {:ok, nil}
  end)

emitted = :counters.get(counter, 1)
v2_count = :counters.get(counter, 2)
v2_with_operation_id_count = :counters.get(counter, 3)

if emitted != n do
  raise "generated #{emitted} cases but #{n} were requested"
end

File.write!(Path.join(out_dir, "V2_COUNT"), Integer.to_string(v2_count) <> "\n")

File.write!(
  Path.join(out_dir, "V2_WITH_OPERATION_ID_COUNT"),
  Integer.to_string(v2_with_operation_id_count) <> "\n"
)

IO.puts(
  :stderr,
  "fuzz_differential.exs: wrote #{emitted} cases (v2=#{v2_count}, " <>
    "with_operation_id=#{v2_with_operation_id_count}, " <>
    "without_operation_id=#{v2_count - v2_with_operation_id_count}) to #{out_dir}"
)
