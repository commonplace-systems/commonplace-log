defmodule Commonplace.Log.Entry do
  @moduledoc """
  Version-1 entry validation (spec §7 shape, §7.1 I-JSON constraints, 1 MiB
  canonical-size cap), mirroring `worker/src/entry.ts` behavior-for-behavior
  on all corpus-pinned classes; known unpinned classes are listed below.
  The shared conformance corpora in `conformance/canonical-json/` and
  `conformance/invalid-entries/` are the arbiters of correctness; error codes
  and reason slugs are cross-runtime contract and must match every
  `error.txt` vector byte-for-byte.

  ## Detection stage vs classification

  The corpus pins the CLASSIFICATION (code + reason slug) of each violation,
  not the stage at which a runtime detects it. Jason and V8's `JSON.parse`
  fail at different points, so this module classifies Jason's decode errors
  back onto the shared slugs:

    * `1e999` (case 023): V8 parses it to `Infinity` and the TypeScript
      validator rejects post-parse; Jason rejects the token at decode. Both
      must emit `invalid_entry` / `non-finite-number`, so a decode failure
      whose token is a grammatically valid JSON number literal is classified
      as `non-finite-number`, not `invalid_json`.
    * `"\\ud800"` (case 024): V8 parses the lone-surrogate escape into an
      ill-formed UTF-16 string and TypeScript rejects post-parse; Jason
      rejects at decode (token is the surrogate escape sequence, or `nil`
      with the error position just past a lone high-surrogate escape). Both
      must emit `invalid_entry` / `ill-formed-unicode`.

  The converse asymmetry: TypeScript must detect unsafe integer literals
  lexically (case 022, `9007199254740993` — V8 silently rounds it), while
  Jason yields exact bignums, so this module finds the same CLASS of
  violation with a post-decode walk. Per the corpus determinism rule, these
  number checks all run before any field check.

  ## Known unpinned class: multi-violation code-level divergence

  An input containing both a Jason-fatal-but-V8-tolerable token AND a later
  grammar error — e.g. `{"a":1e999,"b":}` — diverges at the CODE level, not
  just the slug: Jason halts at the number token, so this module returns
  `invalid_entry` / `non-finite-number`, while V8 tolerates `1e999` (parsing
  it to `Infinity`) and throws at the grammar error, so TypeScript returns
  `invalid_json` / `not-json`. This class is known and deliberately
  UNPINNED: both runtimes reject the entry, and pinning it would force one
  twin to restructure its parser for no interop gain. It is recorded in the
  `conformance/README.md` invalid-entries not-covered list.

  ## Reason slugs

  The slug table below (`@reasons`) is the only place slugs are spelled in
  this runtime. It must stay in lockstep with the `REASONS` table in
  `worker/src/entry.ts` — the two tables are a single cross-runtime
  contract, pinned case-by-case by `conformance/invalid-entries/*/error.txt`.
  """

  alias Commonplace.Log.Jcs

  @type result ::
          {:ok, canonical :: binary()}
          | {:error, code :: String.t(), reason :: String.t()}

  # Keep in lockstep with REASONS in worker/src/entry.ts (see @moduledoc).
  @reasons %{
    not_utf8: "not-utf-8",
    not_json: "not-json",
    entry_not_object: "entry-not-object",
    wrong_version: "wrong-version",
    extra_top_level_field: "extra-top-level-field",
    uuid_not_string: "uuid-not-string",
    uuid_not_lowercase: "uuid-not-lowercase",
    uuid_malformed: "uuid-malformed",
    writer_seq_not_number: "writer-seq-not-number",
    writer_seq_not_integer: "writer-seq-not-integer",
    writer_seq_not_positive: "writer-seq-not-positive",
    prev_entry_id_not_null_at_seq_1: "prev-entry-id-not-null-at-seq-1",
    prev_entry_id_null_after_seq_1: "prev-entry-id-null-after-seq-1",
    created_at_not_string: "created-at-not-string",
    created_at_not_rfc3339: "created-at-not-rfc3339",
    created_at_not_utc: "created-at-not-utc",
    created_at_leap_second: "created-at-leap-second",
    body_not_object: "body-not-object",
    unsafe_integer: "unsafe-integer",
    non_finite_number: "non-finite-number",
    ill_formed_unicode: "ill-formed-unicode",
    canonical_bytes_over_1mib: "canonical-bytes-over-1mib"
  }

  defp reason(key), do: Map.fetch!(@reasons, key)
  defp missing_field(field), do: "missing-field-#{String.replace(field, "_", "-")}"

  @max_canonical_bytes 1_048_576
  @max_safe_integer 9_007_199_254_740_991

  # Spec §7 field table order; checks run in this order, deterministically.
  @required_fields ~w(version log_id entry_id writer_id writer_seq prev_entry_id created_at body)

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  # RFC 3339 date-time restricted to the Z (UTC) offset form; any numeric
  # offset — including +00:00 — is rejected as not-utc so both runtimes
  # accept exactly one spelling of each instant.
  @rfc3339_utc_re ~r/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/
  @rfc3339_offset_re ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2}$/

  # Classifiers for Jason.DecodeError tokens (see @moduledoc): a complete
  # JSON number literal, and a run of \uXXXX escapes starting in the
  # surrogate range D800-DFFF.
  @json_number_re ~r/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/
  @surrogate_escape_run_re ~r/^\\u[dD][89a-fA-F][0-9a-fA-F]{2}(?:\\u[0-9a-fA-F]{4})*$/
  @high_surrogate_escape_re ~r/^\\u[dD][89abAB][0-9a-fA-F]{2}$/

  @doc """
  Validate `raw` bytes as a version-1 entry.

  Returns `{:ok, canonical_bytes}` (the RFC 8785 canonical form, at most
  1 MiB) or `{:error, code, reason}` with `code` one of `"invalid_json"`,
  `"invalid_entry"`, `"entry_too_large"` and `reason` a shared cross-runtime
  slug.
  """
  @spec validate_entry(binary()) :: result()
  def validate_entry(raw) when is_binary(raw) do
    with :ok <- check_utf8(raw),
         {:ok, parsed} <- decode(raw),
         :ok <- check_safe_integers(parsed),
         {:ok, entry} <- check_object(parsed),
         :ok <- check_fields(entry) do
      canonical = Jcs.canonicalize(entry)

      if byte_size(canonical) > @max_canonical_bytes do
        {:error, "entry_too_large", reason(:canonical_bytes_over_1mib)}
      else
        {:ok, canonical}
      end
    end
  end

  defp invalid(reason_key), do: {:error, "invalid_entry", reason(reason_key)}

  defp check_utf8(raw) do
    if String.valid?(raw) do
      :ok
    else
      {:error, "invalid_json", reason(:not_utf8)}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, %Jason.DecodeError{} = error} -> classify_decode_error(error, raw)
    end
  end

  # Jason fails at decode on inputs V8 accepts; map those failures onto the
  # shared classification (probed against Jason 1.x — see @moduledoc):
  #   * an unrepresentable-but-grammatical number literal ("1e999") fails
  #     with the maximal number token -> non-finite-number;
  #   * a lone low surrogate or a high surrogate followed by a non-low
  #     escape fails with the escape run as the token -> ill-formed-unicode;
  #   * a lone high surrogate followed by a non-escape (or string end) fails
  #     with token nil, position just past the 6-byte escape
  #     -> ill-formed-unicode;
  #   * anything else is genuinely malformed JSON -> invalid_json/not-json.
  # A Jason upgrade that changes DecodeError shapes (token/position) turns
  # corpus cases 023/024 and the local classifier-branch regression tests in
  # entry_test.exs red — treat those failures as this classifier needing
  # re-probing, not as corpus problems.
  defp classify_decode_error(%Jason.DecodeError{token: token, position: position}, raw) do
    cond do
      is_binary(token) and Regex.match?(@json_number_re, token) ->
        invalid(:non_finite_number)

      is_binary(token) and Regex.match?(@surrogate_escape_run_re, token) ->
        invalid(:ill_formed_unicode)

      token == nil and position >= 6 and
          Regex.match?(@high_surrogate_escape_re, binary_part(raw, position - 6, 6)) ->
        invalid(:ill_formed_unicode)

      true ->
        {:error, "invalid_json", reason(:not_json)}
    end
  end

  # I-JSON safe-integer rule, run before all field checks (corpus determinism
  # rule). TypeScript detects the raw literal lexically because V8 rounds
  # unsafe integers at parse; Jason yields exact bignums, so the same class
  # of violation is found on the parsed values (case 022 pins the
  # classification). Floats are exempt: Jason floats are always finite, and
  # exponent spellings such as 1e30 denote doubles (the writer_seq value rule
  # handles those, case 030).
  defp check_safe_integers(value) do
    case find_unsafe_integer(value) do
      nil -> :ok
      reason_key -> invalid(reason_key)
    end
  end

  defp find_unsafe_integer(v) when is_integer(v) do
    if abs(v) > @max_safe_integer, do: :unsafe_integer, else: nil
  end

  defp find_unsafe_integer(list) when is_list(list) do
    Enum.find_value(list, &find_unsafe_integer/1)
  end

  defp find_unsafe_integer(map) when is_map(map) do
    Enum.find_value(map, fn {_key, v} -> find_unsafe_integer(v) end)
  end

  defp find_unsafe_integer(_other), do: nil

  defp check_object(parsed) when is_map(parsed), do: {:ok, parsed}
  defp check_object(_parsed), do: invalid(:entry_not_object)

  defp check_fields(entry) do
    Enum.find_value(@required_fields, fn field ->
      unless Map.has_key?(entry, field) do
        {:error, "invalid_entry", missing_field(field)}
      end
    end) ||
      Enum.find_value(Map.keys(entry), fn key ->
        unless key in @required_fields, do: invalid(:extra_top_level_field)
      end) ||
      check_values(entry)
  end

  defp check_values(entry) do
    with :ok <- check_version(entry["version"]),
         :ok <- check_uuids(entry),
         {:ok, writer_seq} <- check_writer_seq(entry["writer_seq"]),
         :ok <- check_prev_entry_id(entry["prev_entry_id"], writer_seq),
         :ok <- check_created_at(entry["created_at"]),
         :ok <- check_body(entry["body"]) do
      :ok
    end
  end

  # Value-based like writer_seq (case 018): 1.0 == 1 passes; anything else —
  # 2, "1", non-numbers — is wrong-version. Elixir's == compares mixed
  # int/float numerically and never equates non-numbers to 1, mirroring the
  # TypeScript `entry["version"] !== 1` double comparison.
  defp check_version(version) do
    if is_number(version) and version == 1, do: :ok, else: invalid(:wrong_version)
  end

  defp check_uuids(entry) do
    Enum.find_value(~w(log_id entry_id writer_id), fn field ->
      case uuid_problem(entry[field]) do
        nil -> nil
        reason_key -> invalid(reason_key)
      end
    end) || :ok
  end

  # Integer-field semantics are VALUE-based (conformance cases 018 and 030):
  # the JSON spelling is irrelevant — 27.0 and 27 are the same double, and
  # canonicalize/1 emits identical bytes for either — but the VALUE must be
  # a safe integer (integral, |v| <= 2^53-1). This mirrors TypeScript's
  # Number.isSafeInteger: it rejects both fractional values (1.5) and
  # integral doubles beyond the safe range (1e30). Deliberately different
  # from the body big-int rule (case 022), which is lexical in TypeScript
  # and a bignum walk here.
  defp check_writer_seq(writer_seq) do
    cond do
      not is_number(writer_seq) -> invalid(:writer_seq_not_number)
      not safe_integer_value?(writer_seq) -> invalid(:writer_seq_not_integer)
      writer_seq < 1 -> invalid(:writer_seq_not_positive)
      true -> {:ok, writer_seq}
    end
  end

  defp safe_integer_value?(v) when is_integer(v), do: abs(v) <= @max_safe_integer
  defp safe_integer_value?(v) when is_float(v), do: v == trunc(v) and abs(v) <= @max_safe_integer

  defp check_prev_entry_id(prev_entry_id, writer_seq) do
    cond do
      writer_seq == 1 and prev_entry_id != nil -> invalid(:prev_entry_id_not_null_at_seq_1)
      writer_seq == 1 -> :ok
      prev_entry_id == nil -> invalid(:prev_entry_id_null_after_seq_1)
      true -> uuid_check(prev_entry_id)
    end
  end

  defp uuid_check(value) do
    case uuid_problem(value) do
      nil -> :ok
      reason_key -> invalid(reason_key)
    end
  end

  defp uuid_problem(value) when not is_binary(value), do: :uuid_not_string

  defp uuid_problem(value) do
    cond do
      Regex.match?(@uuid_re, value) -> nil
      Regex.match?(@uuid_re, String.downcase(value)) -> :uuid_not_lowercase
      true -> :uuid_malformed
    end
  end

  defp check_created_at(created_at) when not is_binary(created_at) do
    invalid(:created_at_not_string)
  end

  defp check_created_at(created_at) do
    case timestamp_problem(created_at) do
      nil -> :ok
      reason_key -> invalid(reason_key)
    end
  end

  # Validates a created_at value against the corpus-pinned rules: RFC 3339
  # date-time restricted to the Z form, with real calendar arithmetic —
  # deliberately no date-library backstop, mirroring worker/src/entry.ts
  # (whose Date.parse is disqualified for rolling 2026-02-30 over to Mar 2).
  # Leap seconds (:60), which RFC 3339 itself permits, are rejected by corpus
  # policy with their own slug (case 029).
  defp timestamp_problem(value) do
    case Regex.run(@rfc3339_utc_re, value) do
      nil ->
        if Regex.match?(@rfc3339_offset_re, value) do
          :created_at_not_utc
        else
          :created_at_not_rfc3339
        end

      [_, year, month, day, hour, minute, second] ->
        y = String.to_integer(year)
        m = String.to_integer(month)
        d = String.to_integer(day)
        s = String.to_integer(second)

        cond do
          m < 1 or m > 12 or d < 1 or d > days_in_month(y, m) ->
            :created_at_not_rfc3339

          String.to_integer(hour) > 23 or String.to_integer(minute) > 59 ->
            :created_at_not_rfc3339

          s == 60 ->
            :created_at_leap_second

          s > 60 ->
            :created_at_not_rfc3339

          true ->
            nil
        end
    end
  end

  @month_lengths {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

  defp days_in_month(year, 2) do
    if leap_year?(year), do: 29, else: 28
  end

  defp days_in_month(_year, month), do: elem(@month_lengths, month - 1)

  defp leap_year?(year) do
    (rem(year, 4) == 0 and rem(year, 100) != 0) or rem(year, 400) == 0
  end

  # Body must be a JSON object. No post-decode ill-formed-string walk is
  # needed here, unlike TypeScript: Jason rejects lone-surrogate escapes at
  # decode (classified above as ill-formed-unicode), and decoded binaries
  # are always well-formed UTF-8.
  defp check_body(body) when is_map(body), do: :ok
  defp check_body(_body), do: invalid(:body_not_object)
end
