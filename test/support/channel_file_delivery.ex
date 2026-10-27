defmodule Zaq.TestSupport.ChannelFileDelivery do
  @moduledoc """
  Channels journeys shared with future Agent ingress scenarios.

  Uses private source resources and loopback Mattermost HTTP / SMTP stubs.
  Final transport responses wait until every journey reaches its external
  boundary, proving overlap before capture assertions and fixture cleanup.
  These are ZAQ contract tests; real server compatibility belongs upstream.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Storage
  alias Zaq.Storage.StorageEntry
  alias Zaq.Storage.VolumeConfig

  alias Zaq.TestSupport.FileDeliverySmtpStub
  alias Zaq.TestSupport.MattermostHistoryFixture
  alias Zaq.TestSupport.OpenAIStub

  @doc "Delivers through real internal paths with private tasks and external transport stubs."
  def run!(providers, opts \\ []) do
    coordinator = self()
    scopes = Enum.map(providers, &scope!(&1, coordinator, opts))

    tasks =
      Enum.map(scopes, fn scope ->
        Task.async(fn ->
          receive do
            :deliver -> journey!(scope, coordinator)
          after
            30_000 -> flunk("delivery task was not released")
          end
        end)
      end)

    try do
      for task <- tasks do
        Sandbox.allow(Repo, self(), task.pid)
        send(task.pid, :deliver)
      end

      captures =
        Map.new(scopes, fn scope ->
          receive do
            {:delivery_boundary, namespace, boundary_pid, capture}
            when namespace == scope.namespace ->
              {namespace, {boundary_pid, capture}}
          after
            15_000 -> flunk("delivery did not reach the external transport boundary")
          end
        end)

      assert Enum.all?(tasks, &Process.alive?(&1.pid))
      Enum.each(captures, fn {_, {pid, _}} -> send(pid, :accept_delivery) end)

      accepted =
        for task <- tasks do
          receive do
            {:provider_accepted, pid, started, accepted_at, receipt} when pid == task.pid ->
              assert receipt.confirmation == :confirmed
              {pid, started, accepted_at, receipt.message_id}
          after
            60_000 -> flunk("stub transport did not confirm delivery")
          end
        end

      assert Enum.all?(tasks, &Process.alive?(&1.pid))
      assert length(Enum.uniq(Enum.map(accepted, &elem(&1, 3)))) == length(tasks)

      assert Enum.max(Enum.map(accepted, &elem(&1, 1))) <
               Enum.min(Enum.map(accepted, &elem(&1, 2)))

      Enum.each(scopes, &assert_sources_preserved!/1)

      Enum.zip(tasks, scopes)
      |> Enum.each(fn {task, scope} ->
        {_, capture} = Map.fetch!(captures, scope.namespace)

        if scope.provider == :mattermost and scope.files? do
          receive do
            {:delivery_upload, namespace, upload} when namespace == scope.namespace ->
              send(task.pid, {:delivery_upload, namespace, upload})
          after
            5_000 -> flunk("missing multipart upload capture")
          end
        end

        namespace = scope.namespace
        refute_received {:delivery_upload, ^namespace, _}
        send(task.pid, {:readback, capture})
      end)

      results = Enum.map(tasks, &Task.await(&1, 60_000))

      assert Enum.max(Enum.map(accepted, &elem(&1, 1))) <
               Enum.min(Enum.map(results, & &1.finished))

      # Only fixture cleanup removes sources, after proving production preserved them.
      [] =
        Enum.reduce(scopes, scopes, fn scope, remaining ->
          assert_sources_preserved!(scope)
          File.rm_rf!(scope.root)
          refute File.exists?(scope.root)
          remaining = List.delete(remaining, scope)
          Enum.each(remaining, &assert_sources_preserved!/1)
          remaining
        end)

      results
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp scope!(provider, coordinator, opts) do
    namespace = "channel-files-#{Ecto.UUID.generate()}"
    volume = String.replace(namespace, "-", "")
    root = Path.join(VolumeConfig.base_path(), namespace)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    selected = %{name: "selected-#{namespace}.bin", bytes: <<0, 255, 128, 10>> <> namespace}
    other = %{name: "unselected-#{namespace}.txt", bytes: "Leave this file private: #{namespace}"}

    for file <- [selected, other], do: File.write!(Path.join(root, file.name), file.bytes)
    {:ok, person} = People.create_person(%{full_name: namespace})
    actor = %{person_id: person.id}

    disk =
      config!("disk", namespace, %{
        kind: "data_source",
        settings: %{"volumes" => [%{"name" => volume, "path" => namespace}]}
      })

    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(disk)

    records =
      for file <- [selected, other] do
        {:ok, entry} = Storage.file_info(volume, file.name, storage_opts)
        {:ok, _} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})

        event =
          %{provider: "disk", params: %{"config_id" => disk.id, "file_id" => entry.id}}
          |> Event.new(:channels, actor: actor, opts: [action: :data_source_get_file])
          |> NodeRouter.dispatch()

        assert {:ok, %{record: %Record{content: nil} = record}} = event.response
        assert is_binary(record.materialization_handle)
        record
      end

    [record, _unselected] = records
    assert record.mime_type == "application/octet-stream"

    scope = %{
      namespace: namespace,
      root: root,
      selected: selected,
      other: other,
      actor: actor,
      record: record,
      coordinator: coordinator,
      files?: Keyword.get(opts, :files, true)
    }

    Map.merge(scope, destination!(provider, scope))
  end

  defp destination!(:mattermost, scope) do
    handler = &MattermostHistoryFixture.delivery_http(&1, &2, scope.coordinator, scope.namespace)
    {server, endpoint} = OpenAIStub.server(handler, scope.coordinator)
    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec(server, id: scope.namespace))

    config =
      config!("mattermost", scope.namespace, %{
        url: String.trim_trailing(endpoint, "/v1"),
        token: "token-#{scope.namespace}"
      })

    %{
      provider: :mattermost,
      config: config,
      channel_id: "room-#{scope.namespace}",
      thread_id: "root-#{scope.namespace}"
    }
  end

  defp destination!(:email, scope) do
    sender = "sender-#{scope.namespace}@example.test"
    recipient = "recipient-#{scope.namespace}@example.test"
    copied = "copied-#{scope.namespace}@example.test"

    port = FileDeliverySmtpStub.start!(scope.coordinator, scope.namespace)

    config =
      config!("email:smtp", scope.namespace, %{
        url: "smtp://127.0.0.1",
        token: "synthetic-unused",
        settings: %{
          "relay" => "127.0.0.1",
          "port" => to_string(port),
          "tls" => "never",
          "from_email" => sender,
          "from_name" => scope.namespace
        }
      })

    %{
      provider: :"email:smtp",
      config: config,
      channel_id: recipient,
      recipient: recipient,
      copied: copied,
      sender: sender,
      thread_id: "parent-#{scope.namespace}@example.test"
    }
  end

  defp config!(provider, namespace, attrs) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(
      Map.merge(
        %{name: "#{provider}-#{namespace}", provider: provider, kind: "retrieval", enabled: true},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp journey!(scope, coordinator) do
    started = System.monotonic_time()

    event =
      scope
      |> outgoing()
      |> Event.new(:channels, actor: scope.actor, opts: [action: :deliver_outgoing])
      |> NodeRouter.dispatch()

    assert {:ok, %{confirmation: :confirmed} = receipt} = event.response
    send(coordinator, {:provider_accepted, self(), started, System.monotonic_time(), receipt})

    receive do
      {:readback, capture} -> assert_capture!(scope, receipt, capture)
    after
      15_000 -> flunk("transport capture assertions were not released")
    end

    assert_sources_preserved!(scope)
    %{provider: scope.provider, message_id: receipt.message_id, finished: System.monotonic_time()}
  end

  defp outgoing(scope) do
    base = %Outgoing{
      provider: scope.provider,
      channel_id: scope.channel_id,
      body: "Selected file #{scope.namespace}",
      attachments: if(scope.files?, do: [scope.record], else: []),
      routing_context: %{channel_config_id: scope.config.id}
    }

    if scope.provider == :mattermost do
      %{base | thread_id: scope.thread_id}
    else
      %{
        base
        | routing_context:
            Map.put(base.routing_context, :reply_targets, %{
              to: [scope.recipient],
              cc: [scope.copied]
            }),
          thread_anchor: %{"message_id" => scope.thread_id},
          metadata: %{
            "subject" => scope.namespace,
            "threading" => %{"message_id" => "sent-#{scope.namespace}@example.test"}
          }
      }
    end
  end

  defp assert_capture!(%{provider: :mattermost} = scope, receipt, %{
         post: post,
         authorization: auth
       }) do
    assert auth == ["Bearer token-#{scope.namespace}"]
    assert receipt.message_id == "post-#{scope.namespace}"
    assert post["channel_id"] == scope.channel_id
    assert post["root_id"] == scope.thread_id
    assert post["message"] == outgoing(scope).body

    if scope.files? do
      assert post["file_ids"] == ["file-#{scope.namespace}"]

      receive do
        {:delivery_upload, namespace, upload} when namespace == scope.namespace ->
          assert upload.channel_id == scope.channel_id
          assert upload.authorization == ["Bearer token-#{scope.namespace}"]
          assert upload.filename == scope.selected.name
          assert upload.mime_type == scope.record.mime_type
          assert upload.bytes == scope.selected.bytes
          refute upload.bytes == scope.other.bytes
      after
        5_000 -> flunk("missing captured multipart upload")
      end
    else
      assert Map.get(post, "file_ids", []) in [nil, []]
    end
  end

  defp assert_capture!(scope, receipt, %{raw: raw, sender: sender, recipients: recipients}) do
    parsed = Mail.parse(raw)
    assert parsed.headers["message-id"] == "<#{receipt.message_id}>"
    assert parsed.headers["in-reply-to"] == "<#{scope.thread_id}>"
    assert parsed.headers["subject"] == scope.namespace
    assert receipt.audience.sender == scope.sender
    assert Enum.sort(receipt.audience.recipients) == Enum.sort([scope.recipient, scope.copied])
    assert sender == scope.sender
    assert Enum.sort(recipients) == Enum.sort([scope.recipient, scope.copied])
    assert parsed.headers["to"] == [scope.recipient]
    assert parsed.headers["cc"] == [scope.copied]

    if scope.files? do
      assert Mail.get_attachments(parsed) == [{scope.selected.name, scope.selected.bytes}]

      assert Enum.any?(
               parsed.parts,
               &(List.first(&1.headers["content-type"] || []) == scope.record.mime_type)
             )
    else
      assert Mail.get_attachments(parsed) == []
    end
  end

  defp assert_sources_preserved!(scope) do
    for file <- [scope.selected, scope.other] do
      assert File.read!(Path.join(scope.root, file.name)) == file.bytes
    end
  end
end
