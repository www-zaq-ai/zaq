defmodule Zaq.TestSupport.ChannelFileDelivery do
  @moduledoc """
  Real-provider Channels journeys shared with future Agent ingress scenarios.

  Uses uniquely owned source/provider resources and actual recipient readback.
  A post-acceptance barrier keeps concurrent journeys alive until all receipts
  exist, before allowing readback and fixture cleanup. No transport is replaced.
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

  @doc "Delivers through the selected real providers with private, explicitly allowed tasks."
  def run!(providers, opts \\ []) do
    services = services!()
    scopes = Enum.map(providers, &scope!(&1, services, opts))
    coordinator = self()

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

      accepted =
        for task <- tasks do
          receive do
            {:provider_accepted, pid, started, accepted_at, receipt} when pid == task.pid ->
              assert receipt.confirmation == :confirmed
              {pid, started, accepted_at, receipt.message_id}
          after
            60_000 -> flunk("real provider did not confirm delivery")
          end
        end

      assert Enum.all?(tasks, &Process.alive?(&1.pid))
      assert length(Enum.uniq(Enum.map(accepted, &elem(&1, 3)))) == length(tasks)

      assert Enum.max(Enum.map(accepted, &elem(&1, 1))) <
               Enum.min(Enum.map(accepted, &elem(&1, 2)))

      Enum.each(scopes, &assert_sources_preserved!/1)
      Enum.each(tasks, &send(&1.pid, :readback))
      results = Enum.map(tasks, &Task.await(&1, 60_000))

      assert Enum.max(Enum.map(accepted, &elem(&1, 1))) <
               Enum.min(Enum.map(results, & &1.finished))

      # Only fixture cleanup removes sources, after proving production preserved them.
      [] =
        Enum.reduce(scopes, scopes, fn scope, remaining ->
          assert_sources_preserved!(scope)
          File.rm_rf!(scope.root)
          remaining = List.delete(remaining, scope)
          Enum.each(remaining, &assert_sources_preserved!/1)
          remaining
        end)

      results
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp services! do
    path = System.get_env("ZAQ_FILE_DELIVERY_SERVICES")
    assert is_binary(path), "run scripts/test_channel_files.sh to provision the real providers"
    Jason.decode!(File.read!(path))
  end

  defp scope!(provider, services, opts) do
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
      services: services,
      files?: Keyword.get(opts, :files, true)
    }

    Map.merge(scope, destination!(provider, scope))
  end

  defp destination!(:mattermost, scope) do
    services = scope.services
    admin = services["mattermost_admin_token"]
    sender = user!(services, admin, scope.namespace <> "-s")
    recipient = user!(services, admin, scope.namespace <> "-r")

    team_name = "ft-" <> binary_part(String.replace(Ecto.UUID.generate(), "-", ""), 0, 20)

    team =
      mm!(services, sender.token, :post, "/teams",
        json: %{name: team_name, display_name: scope.namespace, type: "O"}
      )

    on_exit(fn -> mm_cleanup(services, admin, "/teams/#{team["id"]}") end)

    mm!(services, sender.token, :post, "/teams/#{team["id"]}/members",
      json: %{team_id: team["id"], user_id: recipient.id}
    )

    channel =
      mm!(services, sender.token, :post, "/channels",
        json: %{
          team_id: team["id"],
          name: scope.namespace,
          display_name: scope.namespace,
          type: "P"
        }
      )

    mm!(services, sender.token, :post, "/channels/#{channel["id"]}/members",
      json: %{user_id: recipient.id}
    )

    root =
      mm!(services, recipient.token, :post, "/posts",
        json: %{channel_id: channel["id"], message: "Private source request #{scope.namespace}"}
      )

    config =
      config!("mattermost", scope.namespace, %{
        url: services["mattermost_url"],
        token: sender.token
      })

    %{
      provider: :mattermost,
      config: config,
      channel_id: channel["id"],
      thread_id: root["id"],
      sender: sender,
      recipient: recipient
    }
  end

  defp destination!(:email, scope) do
    sender = "sender-#{scope.namespace}@example.test"
    recipient = "recipient-#{scope.namespace}@example.test"
    copied = "copied-#{scope.namespace}@example.test"

    config =
      config!("email:smtp", scope.namespace, %{
        url: "smtp://#{scope.services["smtp_host"]}",
        token: "synthetic-unused",
        settings: %{
          "relay" => scope.services["smtp_host"],
          "port" => to_string(scope.services["smtp_port"]),
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

  defp user!(services, admin, name) do
    password = "Synthetic-#{Ecto.UUID.generate()}-123!"
    username = "u" <> binary_part(String.replace(Ecto.UUID.generate(), "-", ""), 0, 20)

    user =
      mm!(services, admin, :post, "/users",
        json: %{username: username, email: "#{name}@example.test", password: password}
      )

    on_exit(fn -> mm_cleanup(services, admin, "/users/#{user["id"]}") end)

    response =
      Req.post!(services["mattermost_url"] <> "/api/v4/users/login",
        json: %{login_id: username, password: password},
        retry: false
      )

    assert response.status == 200
    %{id: user["id"], token: hd(response.headers["token"])}
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
    socket = if scope.provider == :"email:smtp", do: mailpit_socket!(scope.services)

    try do
      started = System.monotonic_time()
      outgoing = outgoing(scope)

      event =
        outgoing
        |> Event.new(:channels, actor: scope.actor, opts: [action: :deliver_outgoing])
        |> NodeRouter.dispatch()

      assert {:ok, %{confirmation: :confirmed} = receipt} = event.response
      send(coordinator, {:provider_accepted, self(), started, System.monotonic_time(), receipt})

      receive do
        :readback -> :ok
      after
        60_000 -> flunk("recipient readback was not released")
      end

      readback!(scope, receipt, socket)
      assert_sources_preserved!(scope)

      %{
        provider: scope.provider,
        message_id: receipt.message_id,
        finished: System.monotonic_time()
      }
    after
      if socket, do: :gun.close(elem(socket, 0))
    end
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

  defp readback!(%{provider: :mattermost} = scope, receipt, _socket) do
    post = mm!(scope.services, scope.recipient.token, :get, "/posts/#{receipt.message_id}")
    assert post["channel_id"] == scope.channel_id
    assert post["user_id"] == scope.sender.id
    assert post["root_id"] == scope.thread_id
    assert post["message"] == outgoing(scope).body

    if scope.files? do
      assert [file_id] = post["file_ids"]
      info = mm!(scope.services, scope.recipient.token, :get, "/files/#{file_id}/info")
      assert info["name"] == scope.selected.name
      assert info["mime_type"] == scope.record.mime_type

      bytes =
        mm!(scope.services, scope.recipient.token, :get, "/files/#{file_id}", decode_body: false)

      assert bytes == scope.selected.bytes
      refute bytes == scope.other.bytes
    else
      assert Map.get(post, "file_ids", []) in [nil, []]
    end
  end

  defp readback!(scope, receipt, socket) do
    message = received_mail!(socket, scope.recipient)
    id = message["ID"]
    url = scope.services["mailpit_url"] <> "/api/v1/message/#{id}/raw"
    response = Req.get!(url, decode_body: false, retry: false)
    assert response.status == 200
    parsed = Mail.parse(response.body)
    assert parsed.headers["message-id"] == "<#{receipt.message_id}>"
    assert parsed.headers["in-reply-to"] == "<#{scope.thread_id}>"
    assert parsed.headers["subject"] == scope.namespace
    assert receipt.audience.sender == scope.sender
    assert Enum.sort(receipt.audience.recipients) == Enum.sort([scope.recipient, scope.copied])
    assert Enum.map(message["To"], & &1["Address"]) == [scope.recipient]
    assert Enum.map(message["Cc"], & &1["Address"]) == [scope.copied]

    if scope.files? do
      assert Mail.get_attachments(parsed) == [{scope.selected.name, scope.selected.bytes}]

      assert Enum.any?(
               parsed.parts,
               &(List.first(&1.headers["content-type"] || []) == scope.record.mime_type)
             )
    else
      assert Mail.get_attachments(parsed) == []
    end

    deleted =
      Req.delete!(scope.services["mailpit_url"] <> "/api/v1/messages",
        json: %{IDs: [id]},
        retry: false
      )

    assert deleted.status in 200..299
  end

  defp mailpit_socket!(services) do
    uri = URI.parse(services["mailpit_url"])
    {:ok, connection} = :gun.open(String.to_charlist(uri.host), uri.port, %{protocols: [:http]})
    {:ok, _} = :gun.await_up(connection, 10_000)
    stream = :gun.ws_upgrade(connection, "/api/events")

    receive do
      {:gun_upgrade, ^connection, ^stream, ["websocket"], _} -> {connection, stream}
    after
      10_000 -> flunk("Mailpit websocket did not connect")
    end
  end

  defp received_mail!({connection, stream} = socket, recipient) do
    receive do
      {:gun_ws, ^connection, ^stream, {:text, json}} ->
        case Jason.decode!(json) do
          %{"Type" => "new", "Data" => message} ->
            if Enum.any?(message["To"], &(&1["Address"] == recipient)),
              do: message,
              else: received_mail!(socket, recipient)

          _ ->
            received_mail!(socket, recipient)
        end
    after
      15_000 -> flunk("SMTP receiver did not emit this journey's accepted-message event")
    end
  end

  defp mm!(services, token, method, path, opts \\ []) do
    response =
      Req.request!(
        [
          url: services["mattermost_url"] <> "/api/v4" <> path,
          method: method,
          auth: {:bearer, token},
          retry: false
        ] ++ opts
      )

    assert response.status in 200..299, "Mattermost #{method} #{path}: HTTP #{response.status}"
    response.body
  end

  defp mm_cleanup(services, token, path) do
    Req.delete(services["mattermost_url"] <> "/api/v4" <> path,
      auth: {:bearer, token},
      retry: false
    )
  end

  defp assert_sources_preserved!(scope) do
    for file <- [scope.selected, scope.other] do
      assert File.read!(Path.join(scope.root, file.name)) == file.bytes
    end
  end
end
