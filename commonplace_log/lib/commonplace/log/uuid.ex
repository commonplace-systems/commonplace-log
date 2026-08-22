defmodule Commonplace.Log.UUID do
  @moduledoc "RFC 9562 UUID version 7 generation."

  @max_timestamp 0xFFFFFFFFFFFF

  @doc "Generate a UUIDv7 using the current Unix millisecond timestamp."
  @spec uuidv7() :: String.t()
  def uuidv7 do
    uuidv7(System.system_time(:millisecond))
  end

  @doc "Generate a UUIDv7 with an explicit 48-bit Unix millisecond timestamp."
  @spec uuidv7(non_neg_integer()) :: String.t()
  def uuidv7(timestamp_ms)
      when is_integer(timestamp_ms) and timestamp_ms >= 0 and timestamp_ms <= @max_timestamp do
    <<random_a::12, random_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    bytes =
      <<timestamp_ms::unsigned-big-48, 7::4, random_a::12, 2::2, random_b::62>>

    hex = Base.encode16(bytes, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  def uuidv7(timestamp_ms) do
    raise ArgumentError,
          "UUIDv7 timestamp must be an integer between 0 and #{@max_timestamp}, got: #{inspect(timestamp_ms)}"
  end
end
