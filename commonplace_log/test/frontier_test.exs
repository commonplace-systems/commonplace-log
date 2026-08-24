defmodule Commonplace.Log.FrontierTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Frontier

  @tip_a "018f0000-0000-7000-8000-00000000000a"
  @tip_b "018f0000-0000-7000-8000-00000000000b"

  test "empty, single-lane, and multi-lane values round trip through canonical bytes" do
    for tips <- [[], [@tip_a], [@tip_b, @tip_a]] do
      frontier = Frontier.new(tips)
      assert {:ok, decoded} = frontier |> Frontier.encode() |> Frontier.decode()
      assert decoded == frontier
    end

    assert Frontier.encode(Frontier.new([])) ==
             ~s({"tips":[],"type":"commonplace.log.frontier/v1"})

    assert Frontier.encode(Frontier.new([@tip_a])) ==
             ~s({"tips":["#{@tip_a}"],"type":"commonplace.log.frontier/v1"})

    assert Frontier.encode(Frontier.new([@tip_b, @tip_a])) ==
             ~s({"tips":["#{@tip_a}","#{@tip_b}"],"type":"commonplace.log.frontier/v1"})
  end

  for {label, bytes, reason} <- [
        {"unsorted tips",
         ~s({"tips":["#{@tip_b}","#{@tip_a}"],"type":"commonplace.log.frontier/v1"}),
         :tips_not_canonical_order},
        {"duplicate tips",
         ~s({"tips":["#{@tip_a}","#{@tip_a}"],"type":"commonplace.log.frontier/v1"}),
         :duplicate_tip},
        {"malformed UUID", ~s({"tips":["not-a-uuid"],"type":"commonplace.log.frontier/v1"}),
         :tip_uuid_malformed},
        {"wrong type", ~s({"tips":[],"type":"commonplace.log.frontier/v2"}), :wrong_type},
        {"extra field", ~s({"extra":true,"tips":[],"type":"commonplace.log.frontier/v1"}),
         :extra_top_level_field}
      ] do
    test "decode rejects #{label} with its own reason" do
      assert_reason(unquote(bytes), unquote(reason))
    end
  end

  test "decode distinguishes lowercase and string UUID violations" do
    assert_reason(
      ~s({"tips":["018F0000-0000-7000-8000-00000000000A"],"type":"commonplace.log.frontier/v1"}),
      :tip_uuid_not_lowercase
    )

    assert_reason(~s({"tips":[7],"type":"commonplace.log.frontier/v1"}), :tip_not_string)
  end

  test "decode rejects non-canonical JSON even when its parsed value is valid" do
    assert_reason(
      ~s({"type":"commonplace.log.frontier/v1", "tips":[]}),
      :non_canonical_encoding
    )
  end

  test "encode refuses a struct that bypassed the canonical constructor invariant" do
    assert_raise ArgumentError, ~r/tips_not_canonical_order/, fn ->
      Frontier.encode(%Frontier{tips: [@tip_b, @tip_a]})
    end
  end

  defp assert_reason(bytes, reason) do
    assert {:error, %Frontier.Error{operation: :decode, reason: ^reason}} =
             Frontier.decode(bytes)
  end
end
