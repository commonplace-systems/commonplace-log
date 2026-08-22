defmodule Commonplace.Log.Jcs do
  @moduledoc """
  RFC 8785 (JCS) canonical JSON serialization.

  `canonicalize/1` returns the canonical UTF-8 bytes for a parsed JSON value
  (as decoded by `Jason.decode!/1`: maps with binary keys, lists, binaries,
  integers, floats, `nil`/`true`/`false`). The shared conformance corpus in
  `conformance/canonical-json/` is the arbiter of correctness; every runtime
  implementation must match it byte-for-byte.

  Two constraints are port-critical and easy to get wrong:

  1. **Object keys sort by UTF-16 code units** (RFC 8785 §3.2.3), not by
     Unicode code points and not by UTF-8 bytes. Keys are transcoded to
     UTF-16 big-endian and compared as plain binaries. The three orderings
     differ for astral-plane keys: U+10000 encodes as surrogate pair
     `D800 DC00`, which sorts *before* U+E000..U+FFFF keys in UTF-16
     code-unit order but *after* them in both code-point and UTF-8 byte
     order. Corpus case `004-sort-astral-before-e000` is the tripwire.

  2. **Numbers serialize per ECMAScript** `Number::toString(x, 10)`
     (RFC 8785 §3.2.2.3 / ECMA-262 §6.1.6.1.20) — never Erlang's default
     float formatting. Erlang renders `1.0e30`; ECMAScript renders `1e+30`
     (explicit `+`, no `.0` mantissa, decimal form only for `1e-6 <= |x| <
     1e21`). Erlang's shortest round-trip digits (`:erlang.float_to_binary/2`
     with `:short`) are reused, but the digit string is reformatted to
     ECMAScript's layout rules. Corpus case `010-num-1e21` (`1e+21`) is the
     tripwire; negative zero must emit `0`.
  """

  @doc """
  Serialize a parsed JSON value to its RFC 8785 canonical UTF-8 bytes.

  Raises `ArgumentError` for terms with no JCS serialization: atoms other
  than `nil`/`true`/`false`, tuples, maps with non-binary keys, etc.
  (Erlang floats are always finite, so NaN/Infinity cannot reach this
  function as floats.)
  """
  @spec canonicalize(term()) :: binary()
  def canonicalize(term) do
    term |> serialize() |> IO.iodata_to_binary()
  end

  defp serialize(nil), do: "null"
  defp serialize(true), do: "true"
  defp serialize(false), do: "false"
  defp serialize(s) when is_binary(s), do: serialize_string(s)
  defp serialize(i) when is_integer(i), do: Integer.to_string(i)
  defp serialize(f) when is_float(f), do: serialize_float(f)

  defp serialize(list) when is_list(list) do
    ["[", Enum.map_intersperse(list, ",", &serialize/1), "]"]
  end

  defp serialize(map) when is_map(map) do
    members =
      map
      |> Map.to_list()
      |> Enum.map(fn
        {key, value} when is_binary(key) -> {utf16_sort_key(key), key, value}
        {key, _value} -> raise ArgumentError, "cannot canonicalize non-binary map key: #{inspect(key)}"
      end)
      |> List.keysort(0)
      |> Enum.map_intersperse(",", fn {_sort_key, key, value} ->
        [serialize_string(key), ":", serialize(value)]
      end)

    ["{", members, "}"]
  end

  defp serialize(other) do
    raise ArgumentError, "cannot canonicalize term: #{inspect(other)}"
  end

  # RFC 8785 §3.2.3: sort property names by their UTF-16 code units.
  # Transcoding to UTF-16 big-endian makes plain binary comparison equal
  # to code-unit comparison. Never compare the UTF-8 binaries directly.
  defp utf16_sort_key(key) do
    case :unicode.characters_to_binary(key, :utf8, {:utf16, :big}) do
      bin when is_binary(bin) -> bin
      _ -> raise ArgumentError, "cannot canonicalize ill-formed UTF-8 key: #{inspect(key)}"
    end
  end

  # RFC 8785 §3.2.2.2: the seven two-char escapes; other chars below 0x20
  # as \u00xx with lowercase hex; everything else (including "/" and all
  # non-ASCII) emitted literally as UTF-8.
  defp serialize_string(s) do
    [?", escape(s), ?"]
  end

  defp escape(<<>>), do: []
  defp escape(<<?\b, rest::binary>>), do: ["\\b" | escape(rest)]
  defp escape(<<?\t, rest::binary>>), do: ["\\t" | escape(rest)]
  defp escape(<<?\n, rest::binary>>), do: ["\\n" | escape(rest)]
  defp escape(<<?\f, rest::binary>>), do: ["\\f" | escape(rest)]
  defp escape(<<?\r, rest::binary>>), do: ["\\r" | escape(rest)]
  defp escape(<<?", rest::binary>>), do: ["\\\"" | escape(rest)]
  defp escape(<<?\\, rest::binary>>), do: ["\\\\" | escape(rest)]

  defp escape(<<b, rest::binary>>) when b < 0x20 do
    [["\\u00", hex_digit(div(b, 16)), hex_digit(rem(b, 16))] | escape(rest)]
  end

  defp escape(<<b, rest::binary>>), do: [b | escape(rest)]

  defp hex_digit(d) when d < 10, do: ?0 + d
  defp hex_digit(d), do: ?a + d - 10

  # RFC 8785 §3.2.2.3: ECMAScript Number::toString(x, 10),
  # ECMA-262 §6.1.6.1.20. Erlang's :short option yields the same shortest
  # round-trip digits as ECMAScript, but in Erlang's own layout
  # ("1.0e30"); reformat to ECMAScript's ("1e+30").
  defp serialize_float(f) do
    if f == 0.0 do
      # Covers -0.0 as well: ECMAScript renders both zeros as "0".
      "0"
    else
      erl = :erlang.float_to_binary(f, [:short])
      {sign, digits, n} = decompose(erl)
      [sign, format_digits(digits, n)]
    end
  end

  # Parse Erlang's :short output ("-?d+.d+(e-?d+)?") into
  # {sign, digit_string, n} with value = sign 0.digits * 10^n
  # (digits has no leading or trailing zeros; the zero value never
  # reaches here).
  defp decompose(erl) do
    {sign, unsigned} =
      case erl do
        <<"-", rest::binary>> -> ["-", rest] |> List.to_tuple()
        _ -> {"", erl}
      end

    {mantissa, exp} =
      case String.split(unsigned, "e") do
        [m] -> {m, 0}
        [m, e] -> {m, String.to_integer(e)}
      end

    [int_part, frac_part] = String.split(mantissa, ".")

    raw = int_part <> frac_part
    e10 = exp - byte_size(frac_part)

    {digits, e10} = strip_trailing_zeros(raw, e10)
    digits = String.trim_leading(digits, "0")

    {sign, digits, byte_size(digits) + e10}
  end

  defp strip_trailing_zeros(digits, e10) do
    case digits do
      <<_::binary>> when byte_size(digits) > 1 ->
        if :binary.last(digits) == ?0 do
          strip_trailing_zeros(binary_part(digits, 0, byte_size(digits) - 1), e10 + 1)
        else
          {digits, e10}
        end

      _ ->
        {digits, e10}
    end
  end

  # ECMA-262 §6.1.6.1.20 steps 5-10, with s = digits, k = length(s),
  # n such that value = 0.s * 10^n.
  defp format_digits(s, n) do
    k = byte_size(s)

    cond do
      k <= n and n <= 21 ->
        # Integer form: digits followed by n-k zeros.
        [s, String.duplicate("0", n - k)]

      0 < n and n <= 21 ->
        # n < k here: decimal point inside the digits.
        [binary_part(s, 0, n), ".", binary_part(s, n, k - n)]

      -6 < n and n <= 0 ->
        ["0.", String.duplicate("0", -n), s]

      true ->
        exponent = n - 1
        exp_sign = if exponent >= 0, do: "+", else: "-"

        mantissa =
          if k == 1 do
            s
          else
            [binary_part(s, 0, 1), ".", binary_part(s, 1, k - 1)]
          end

        [mantissa, "e", exp_sign, Integer.to_string(abs(exponent))]
    end
  end
end
