defmodule CommonplaceNext.Organization.FacetStabilityTest do
  @moduledoc """
  ⭐⭐ THE DISCRIMINATOR FOR RETIRING A FACET (ruled row 641), and it decides whether retiring one
  costs anything at all.

  `ORG-2a` deletes the orphan `:biscuit_issuer` facet. If the derivation were ORDER-keyed, removing
  a facet would silently move every id derived after it -- workspace cells, root directories, seeded
  documents -- and a dev store that re-seeds would hide the move behind fresh data. If it is
  NAME-keyed, removal touches nothing but itself.

  ⛔ THE EXPECTED VALUES WERE CAPTURED AT THE BASE TREE `b1842e1`, BEFORE THE DELETION, and are
  written here as literals ON PURPOSE. Generating them from the current tree would make this arm
  agree with whatever the code does today -- the definition of a vacuous test. These are the numbers
  the PREVIOUS tree produced; the arm asserts this tree still produces them.
  """
  use ExUnit.Case, async: true

  alias CommonplaceNext.Organization.Identity

  # A fixed Organization id: the arm is about the FACET keying, so the organization must be a
  # constant or a changed default would read as a changed derivation.
  @organization "01990000-0000-7000-8000-00000000000a"

  # `[measured at b1842e1, before :biscuit_issuer was deleted]`
  @derived_at_base %{
    authority_cell: "8bdd039d-1f22-75b7-bb02-eefa76a9bbac",
    editor_cell: "1d916912-ca42-7fb4-bacf-966bcd8237fb",
    editor_root_directory: "410901ed-9546-7b05-9845-87a5e9bcd0e3",
    owner_membership: "785b246c-0795-7d27-9f4b-be99152e5d42",
    root_directory: "c40583de-df2d-7970-a6c3-199586a801b7",
    seed_document: "429abb11-7d19-7c2a-9bbf-ad5c1fde7d8a",
    session_cell: "5dcc7035-54b0-7ba9-8363-5d240beb9ee7",
    space: "754e1ce2-cd6e-7d37-b32b-3c664453ecb7",
    workspace_cell: "3d949c46-8d39-735a-ac4a-5cb79ba39904"
  }

  # The discriminated form derives through the same `hash_input/2`, so it would move for the same
  # reason. `[measured at b1842e1]`
  @discriminated_session_cell_at_base "5de31f25-9992-7d83-838a-dfb4754ca968"

  test "retiring a facet leaves every other facet's derived id unchanged" do
    for {facet, expected} <- @derived_at_base do
      assert Identity.derive(@organization, facet) == expected,
             "#{facet} derived #{Identity.derive(@organization, facet)}, but the tree before the " <>
               "facet was retired derived #{expected} -- the derivation is order-keyed, and " <>
               "retiring a facet has moved identities that already name real data"
    end
  end

  test "the discriminated derivation is unchanged too" do
    assert Identity.derive(@organization, :session_cell, "s1") ==
             @discriminated_session_cell_at_base
  end

  # ⛔ THE CONTROL, because the arm above is a list of equalities and equalities pass when the
  # instrument is dead. If `derive/2` returned a constant, or the facet name stopped reaching the
  # hash, every assertion above would still hold for the wrong reason.
  test "the instrument can tell facets apart" do
    ids = Enum.map(Map.keys(@derived_at_base), &Identity.derive(@organization, &1))
    assert length(Enum.uniq(ids)) == length(ids), "two facets derived the same id"

    refute Identity.derive(@organization, :space) ==
             Identity.derive("01990000-0000-7000-8000-00000000000b", :space),
           "two different Organizations derived the same id -- the organization is not reaching the hash"
  end

  # ⭐ AND THE RETIREMENT ITSELF IS ASSERTED, so "the facet is gone" is a fact this suite carries
  # rather than a thing a reader has to check by grep.
  test "the retired facet is gone" do
    refute :biscuit_issuer in Identity.facets()

    assert_raise KeyError, fn -> Identity.derive(@organization, :biscuit_issuer) end
  end
end
