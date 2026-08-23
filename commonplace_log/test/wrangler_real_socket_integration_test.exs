if System.get_env("RUN_WRANGLER_INTEGRATION") == "1" do
  defmodule Commonplace.Log.WranglerRealSocketIntegrationTest do
    use ExUnit.Case, async: false

    alias Commonplace.Log.{Engine, Jcs}
    alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan, ReadSet}
    alias Commonplace.Log.Persistence.CloudflareSidecar.Httpc

    @log_id "018f1000-0000-7000-8000-000000000001"
    @writer_id "018f1000-0000-7000-8000-000000000002"
    @entry_id "018f1000-0000-7000-8000-000000000003"
    @fork_entry_id "018f1000-0000-7000-8000-000000000004"
    @wire_bytes <<0, 127, 128, 254, 255>>

    defmodule WranglerProcess do
      use GenServer

      def start_link(options), do: GenServer.start_link(__MODULE__, options)
      def details(pid), do: GenServer.call(pid, :details)
      def stop(pid), do: GenServer.stop(pid, :normal, 15_000)

      @impl true
      def init(options) do
        worker_dir = Keyword.fetch!(options, :worker_dir)
        scratch_dir = Keyword.fetch!(options, :scratch_dir)
        port_number = Keyword.fetch!(options, :port)
        node = System.find_executable("node") || raise "node executable not found"
        wrangler = Path.join(worker_dir, "node_modules/wrangler/bin/wrangler.js")
        config = Path.join(worker_dir, "wrangler.integration.jsonc")

        args = [
          wrangler,
          "dev",
          "--config",
          config,
          "--ip",
          "127.0.0.1",
          "--port",
          Integer.to_string(port_number),
          "--persist-to",
          Path.join(scratch_dir, "state")
        ]

        port =
          Port.open({:spawn_executable, node}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, Enum.map(args, &String.to_charlist/1)},
            {:cd, String.to_charlist(worker_dir)},
            {:env,
             [
               {~c"WRANGLER_LOG_PATH",
                scratch_dir |> Path.join("wrangler.log") |> String.to_charlist()},
               {~c"XDG_CONFIG_HOME", scratch_dir |> Path.join("config") |> String.to_charlist()}
             ]}
          ])

        os_pid = Port.info(port, :os_pid) |> elem(1)
        {:ok, %{port: port, os_pid: os_pid, output: [], exit_status: nil}}
      end

      @impl true
      def handle_call(:details, _from, state) do
        output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
        {:reply, %{os_pid: state.os_pid, output: output, exit_status: state.exit_status}, state}
      end

      @impl true
      def handle_info({_port, {:data, data}}, state) do
        {:noreply, %{state | output: [data | state.output]}}
      end

      def handle_info({_port, {:exit_status, status}}, state) do
        {:noreply, %{state | exit_status: status}}
      end

      @impl true
      def terminate(_reason, state) do
        if state.exit_status == nil do
          System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
          await_exit(state.os_pid, System.monotonic_time(:millisecond) + 10_000)
        end

        if Port.info(state.port) != nil, do: Port.close(state.port)
        :ok
      end

      defp await_exit(os_pid, deadline) do
        case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
          {_output, 0} ->
            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(25)
              await_exit(os_pid, deadline)
            else
              raise "wrangler PID #{os_pid} did not exit after SIGTERM"
            end

          {_output, _status} ->
            :ok
        end
      end
    end

    setup_all do
      worker_dir = System.fetch_env!("COMMONPLACE_LOG_WORKER_DIR") |> Path.expand()

      scratch_dir =
        Path.join(System.tmp_dir!(), "wrangler-real-socket-#{System.unique_integer([:positive])}")

      File.mkdir_p!(scratch_dir)
      port_number = free_port()

      {:ok, wrangler} =
        WranglerProcess.start_link(
          worker_dir: worker_dir,
          scratch_dir: scratch_dir,
          port: port_number
        )

      on_exit(fn ->
        if Process.alive?(wrangler), do: WranglerProcess.stop(wrangler)
        File.rm_rf!(scratch_dir)
      end)

      await_ready(wrangler, port_number, System.monotonic_time(:millisecond) + 20_000)
      %{wrangler: wrangler, port: port_number, base_url: "http://127.0.0.1:#{port_number}"}
    end

    test "adapter and Engine exercise the realm contract through Wrangler", context do
      %{os_pid: os_pid} = WranglerProcess.details(context.wrangler)
      IO.puts("WRANGLER_READY pid=#{os_pid} port=#{context.port}")

      # Positive control MUST remain the first HTTP request in this test.
      assert {:ok, %{status: 400, body: malformed_body}} =
               await_positive_control(
                 context.base_url,
                 context.wrangler,
                 System.monotonic_time(:millisecond) + 10_000
               )

      assert %{"ok" => false, "error" => %{"code" => "malformed_request"}} =
               Jason.decode!(malformed_body)

      IO.puts("POSITIVE_CONTROL status=400 body=#{malformed_body}")

      adapter_base_url = adapter_base_url(context.base_url)

      store =
        CloudflareSidecar.new(adapter_base_url,
          transport_options: [timeout: 5_000, connect_timeout: 5_000]
        )

      assert :ok =
               CloudflareSidecar.create_log(store, @log_id, %{
                 format_version: 1,
                 created_at: "2026-08-23T00:00:00Z"
               })

      assert {:ok, 1} = CloudflareSidecar.take_lease(store, @log_id)
      assert {:ok, 1} = CloudflareSidecar.commit(store, initial_plan())

      assert {:ok,
              %ReadSet{
                revision: 1,
                lease_epoch: 1,
                tips: %{@writer_id => %{seq: 1, entry_id: @entry_id}},
                coordinates: %{{@writer_id, 1} => @wire_bytes},
                entry_ids: %{@entry_id => @wire_bytes}
              }} =
               CloudflareSidecar.read_set(store, @log_id, %{
                 writers: [@writer_id],
                 coordinates: [{@writer_id, 1}],
                 entry_ids: [@entry_id]
               })

      assert {:ok, %{writers: [%{writer_id: @writer_id, seq: 1, entry_id: @entry_id}]}} =
               CloudflareSidecar.frontier(store, @log_id)

      assert {:ok,
              %{entries: [%{canonical_bytes: @wire_bytes, writer_seq: 1}], next_after_seq: nil}} =
               CloudflareSidecar.read_writer(store, @log_id, @writer_id,
                 after_seq: 0,
                 through_seq: 1,
                 limit: 10
               )

      assert {:ok,
              %{
                entries: [%{canonical_bytes: @wire_bytes, arrival_seq: 1}],
                next_after_arrival: nil
              }} = CloudflareSidecar.tail_local(store, @log_id, after_arrival: 0, limit: 10)

      assert {:error, :stale_revision} =
               CloudflareSidecar.commit(store, %CommitPlan{
                 log_id: @log_id,
                 expected_revision: 0,
                 expected_epoch: 1
               })

      assert {:ok, 2} = CloudflareSidecar.take_lease(store, @log_id)

      assert {:error, :obsolete_epoch} =
               CloudflareSidecar.commit(store, %CommitPlan{
                 log_id: @log_id,
                 expected_revision: 1,
                 expected_epoch: 1
               })

      assert_unknown_log(store)

      assert {:error, {:writer_fork, %{writer_id: @writer_id, seq: 1}}} =
               Engine.merge(CloudflareSidecar, store, @log_id, [fork_entry()])
    end

    defp initial_plan do
      %CommitPlan{
        log_id: @log_id,
        expected_revision: 0,
        expected_epoch: 1,
        insert_entries: [
          %{
            log_id: @log_id,
            entry_id: @entry_id,
            writer_id: @writer_id,
            writer_seq: 1,
            prev_entry_id: nil,
            created_at: "2026-08-23T00:01:00Z",
            canonical_bytes: @wire_bytes
          }
        ],
        put_tips: [%{writer_id: @writer_id, seq: 1, entry_id: @entry_id}]
      }
    end

    defp fork_entry do
      Jcs.canonicalize(%{
        "version" => 1,
        "log_id" => @log_id,
        "entry_id" => @fork_entry_id,
        "writer_id" => @writer_id,
        "writer_seq" => 1,
        "prev_entry_id" => nil,
        "created_at" => "2026-08-23T00:02:00Z",
        "body" => %{"fork" => true}
      })
    end

    defp assert_unknown_log(store) do
      missing = "018f1000-0000-7000-8000-000000000099"
      query = %{writers: [], coordinates: [], entry_ids: []}
      assert {:error, :not_found} = CloudflareSidecar.read_set(store, missing, query)
      assert {:error, :not_found} = CloudflareSidecar.frontier(store, missing)

      assert {:error, :not_found} =
               CloudflareSidecar.read_writer(store, missing, @writer_id, after_seq: 0, limit: 1)

      assert {:error, :not_found} =
               CloudflareSidecar.tail_local(store, missing, after_arrival: 0, limit: 1)
    end

    defp free_port do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
      :ok = :gen_tcp.close(socket)
      port
    end

    defp adapter_base_url(wrangler_base_url) do
      if System.get_env("WRANGLER_INTEGRATION_RED_ARM") == "wrong_port" do
        wrong_base_url = "http://127.0.0.1:#{free_port()}"
        true = wrong_base_url != wrangler_base_url

        IO.puts(
          "SABOTAGE_APPLIED adapter_base=#{wrong_base_url} wrangler_base=#{wrangler_base_url}"
        )

        wrong_base_url
      else
        wrangler_base_url
      end
    end

    defp await_positive_control(base_url, wrangler, deadline) do
      result =
        Httpc.request(
          :post,
          base_url <> "/create-log",
          [{"content-type", "application/json"}],
          "{",
          timeout: 1_000,
          connect_timeout: 1_000
        )

      case result do
        {:ok, _response} ->
          result

        {:error, _reason} ->
          details = WranglerProcess.details(wrangler)

          cond do
            details.exit_status != nil ->
              raise "wrangler exited with #{details.exit_status}:\n#{details.output}"

            System.monotonic_time(:millisecond) < deadline ->
              Process.sleep(50)
              await_positive_control(base_url, wrangler, deadline)

            true ->
              raise "positive control timed out with #{inspect(result)}:\n#{details.output}"
          end
      end
    end

    defp await_ready(wrangler, port, deadline) do
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :ok = :gen_tcp.close(socket)

        {:error, _reason} ->
          details = WranglerProcess.details(wrangler)

          cond do
            details.exit_status != nil ->
              raise "wrangler exited with #{details.exit_status}:\n#{details.output}"

            System.monotonic_time(:millisecond) >= deadline ->
              raise "wrangler was not ready before timeout:\n#{details.output}"

            true ->
              Process.sleep(50)
              await_ready(wrangler, port, deadline)
          end
      end
    end
  end
end
