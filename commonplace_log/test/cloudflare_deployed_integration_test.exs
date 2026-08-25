defmodule Commonplace.Log.CloudflareDeployedIntegrationTest do
  @moduledoc """
  Two-realm isolation check against a REAL deployed gateway
  (docs/sp4b-deployment-readiness.md §3/§5, path-derived form).

  Runs only when both `COMMONPLACE_LOG_GATEWAY_URL` and
  `COMMONPLACE_LOG_GATEWAY_TOKEN` are set; otherwise the module is skipped.
  `COMMONPLACE_LOG_GATEWAY_TOKEN` is the deployment token: it creates realms
  but does not authorize their data routes. The token and returned realm
  secrets are read at test time and never printed.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Log.{DocumentProfile, UUID}
  alias Commonplace.Log.DocumentProfile.Lane.Sidecar, as: SidecarLane
  alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan, ReadSet}
  alias Commonplace.Log.Persistence.CloudflareSidecar.Httpc

  @url_var "COMMONPLACE_LOG_GATEWAY_URL"
  @token_var "COMMONPLACE_LOG_GATEWAY_TOKEN"

  if System.get_env(@url_var) in [nil, ""] or System.get_env(@token_var) in [nil, ""] do
    @moduletag skip: "set #{@url_var} and #{@token_var} to run against a real deployment"
  end

  @wire_bytes <<0, 127, 128, 254, 255>>
  @transport_options [timeout: 15_000, connect_timeout: 10_000]

  test "a log committed in realm A is present there and absent from realm B" do
    gateway_url = System.fetch_env!(@url_var) |> String.trim_trailing("/")
    deployment_token = System.fetch_env!(@token_var)

    log_id = UUID.uuidv7()
    writer_id = UUID.uuidv7()
    entry_id = UUID.uuidv7()
    realm_a_id = UUID.uuidv7()
    realm_b_id = UUID.uuidv7()

    assert {:ok, realm_a_secret} = create_realm(gateway_url, realm_a_id, deployment_token)
    assert {:ok, realm_b_secret} = create_realm(gateway_url, realm_b_id, deployment_token)

    realm_a = adapter(gateway_url, realm_a_id, realm_a_secret)
    realm_b = adapter(gateway_url, realm_b_id, realm_b_secret)
    wrong_secret = adapter(gateway_url, realm_a_id, "obviously-wrong-realm-secret")
    realm_b_secret_on_a = adapter(gateway_url, realm_a_id, realm_b_secret)

    # Realm A: create, lease, commit one entry, then read the frontier back.
    assert :ok =
             CloudflareSidecar.create_log(realm_a, log_id, %{
               format_version: 1,
               created_at: "2026-08-24T00:00:00Z"
             })

    assert {:ok, %{lease_epoch: epoch}} = CloudflareSidecar.take_lease(realm_a, log_id)
    assert {:ok, 1} = CloudflareSidecar.commit(realm_a, plan(log_id, writer_id, entry_id, epoch))

    # Positive control: presence in realm A, before any absence claim.
    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: 1, entry_id: ^entry_id}]}} =
             CloudflareSidecar.frontier(realm_a, log_id)

    assert {:ok, %ReadSet{log_id: ^log_id, revision: 1, entry_ids: %{^entry_id => @wire_bytes}}} =
             CloudflareSidecar.read_set(realm_a, log_id, %{
               writers: [writer_id],
               coordinates: [],
               entry_ids: [entry_id]
             })

    # Isolation: the same log_id does not exist in realm B (sidecar answers 404 not_found).
    assert {:error, :not_found} = CloudflareSidecar.frontier(realm_b, log_id)

    assert {:error, :not_found} =
             CloudflareSidecar.read_set(realm_b, log_id, %{
               writers: [],
               coordinates: [],
               entry_ids: []
             })

    # Authentication: neither a wrong secret nor realm B's secret opens realm A.
    assert {:error, {:unauthorized, %{status: 401, body: body}}} =
             CloudflareSidecar.frontier(wrong_secret, log_id)

    assert %{"ok" => false, "error" => %{"code" => "unauthorized"}} = Jason.decode!(body)

    assert {:error, {:unauthorized, %{status: 401, body: cross_body}}} =
             CloudflareSidecar.frontier(realm_b_secret_on_a, log_id)

    assert %{"ok" => false, "error" => %{"code" => "unauthorized"}} =
             Jason.decode!(cross_body)
  end

  test "DocumentProfile over a deployed sidecar keeps one writer and fences an old activation" do
    gateway_url = System.fetch_env!(@url_var) |> String.trim_trailing("/")
    deployment_token = System.fetch_env!(@token_var)
    realm_id = UUID.uuidv7()
    assert {:ok, realm_secret} = create_realm(gateway_url, realm_id, deployment_token)
    store = adapter(gateway_url, realm_id, realm_secret)
    log_id = UUID.uuidv7()
    lane = [lane: {SidecarLane, store}]

    assert {:ok, first} = DocumentProfile.create_log(log_id, lane)
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(first, %{"n" => 1}, [])
    writer_id = first.writer_id
    assert {:ok, second} = DocumentProfile.open_log(log_id, lane)
    assert second.writer_id == writer_id
    assert {:ok, before_frontier} = CloudflareSidecar.frontier(store, log_id)

    assert {:error, {:writer_lease_fenced, %{}}} =
             DocumentProfile.append(first, %{"must_not_write" => true}, [])

    assert {:ok, after_frontier} = CloudflareSidecar.frontier(store, log_id)
    assert after_frontier == before_frontier
    assert {:ok, %{writer_seq: 2}} = DocumentProfile.append(second, %{"n" => 2}, [])
  end

  defp create_realm(gateway_url, realm_id, deployment_token) do
    case Httpc.request(
           :post,
           gateway_url <> "/realms/" <> realm_id,
           [
             {"content-type", "application/json"},
             {"authorization", "Bearer " <> deployment_token}
           ],
           "{}",
           @transport_options
         ) do
      {:ok, %{status: 201, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "realm_id" => ^realm_id, "realm_secret" => secret}}
          when is_binary(secret) ->
            {:ok, secret}

          _response ->
            # Never place a one-time realm secret in a failing assertion term.
            {:error, :unexpected_create_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:realm_create_failed, status}}

      {:error, reason} ->
        {:error, {:realm_create_transport_failed, reason}}

      _response ->
        {:error, :malformed_create_transport_response}
    end
  end

  defp adapter(gateway_url, realm_id, realm_secret) do
    CloudflareSidecar.new(gateway_url <> "/realms/" <> realm_id,
      transport_options: @transport_options,
      headers: [{"authorization", "Bearer " <> realm_secret}]
    )
  end

  defp plan(log_id, writer_id, entry_id, epoch) do
    %CommitPlan{
      log_id: log_id,
      expected_revision: 0,
      expected_epoch: epoch,
      insert_entries: [
        %{
          log_id: log_id,
          entry_id: entry_id,
          writer_id: writer_id,
          writer_seq: 1,
          prev_entry_id: nil,
          created_at: "2026-08-24T00:01:00Z",
          canonical_bytes: @wire_bytes
        }
      ],
      put_tips: [%{writer_id: writer_id, seq: 1, entry_id: entry_id}]
    }
  end
end
