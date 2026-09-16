defmodule ZaqWeb.PeopleBrowserTest do
  use ZaqWeb.ConnCase, async: false
  @moduletag :real_browser

  import Mox
  alias Zaq.Accounts.{People, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.PeopleAuthDeliveryMock
  alias Zaq.Channels.PeopleAuthRateLimiter.Config
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.PeopleAuthDelivery
  alias Zaq.TestSupport.PeopleSourceFixture
  import Zaq.AccountsFixtures

  setup :verify_on_exit!

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 180_000
    test "#{engine}: mobile/desktop sign-in, resend and independent BO/People logout" do
      engine = unquote(engine)
      suffix = "#{engine}-#{System.unique_integer([:positive])}"
      disk = Application.fetch_env!(:zaq, :channels) |> Map.fetch!(:disk)
      PeopleAuthDelivery.setup()

      Application.put_env(
        :zaq,
        :channels,
        Map.put(Application.fetch_env!(:zaq, :channels), :disk, disk)
      )

      set_mox_global()

      for width <- [390, 1280] do
        {:ok, person} =
          People.create_person(%{
            full_name: "Browser Person",
            email: "#{suffix}-#{width}@example.test"
          })

        {:ok, _} =
          People.add_channel(%{
            person_id: person.id,
            platform: "slack",
            channel_identifier: "browser-slack-#{width}"
          })

        {:ok, conversation} =
          Conversations.create_conversation(%{
            person_id: person.id,
            title: "Browser history #{width}",
            channel_type: "api"
          })

        incoming = %Incoming{
          content: "Browser input",
          channel_id: "api",
          provider: "api",
          metadata: %{conversation_id: conversation.id},
          attachments: [
            %Record{
              id: "notes",
              kind: :file,
              name: "notes.txt",
              size: 12,
              mime_type: "text/plain"
            }
          ]
        }

        {:ok, _} =
          Conversations.persist_from_incoming(incoming, %{
            answer: "Browser history answer",
            trace: [
              %{
                "id" => "browser-trace",
                "tool_name" => "History inspection",
                "response" => %{"visible" => "trace details"}
              }
            ],
            trace_artifacts: [
              %{
                tool_call_id: "browser-trace",
                tool_name: "download_document",
                content: "Browser artifact",
                name: "browser-evidence.txt",
                mime_type: "text/plain",
                record: %{"attributes" => %{"source_type" => "communication_media"}}
              }
            ]
          })

        document =
          PeopleSourceFixture.create(person, "# Browser source\nAuthorized source material")

        {:ok, _} =
          Conversations.add_message(conversation, %{
            role: "assistant",
            content: "Additional source",
            sources: [%{"type" => "document", "index" => 1, "path" => document.source}]
          })

        for n <- 1..26 do
          {:ok, _} =
            Conversations.create_conversation(%{
              person_id: person.id,
              title: "Archived history #{n}",
              channel_type: "slack",
              status: "archived"
            })
        end
      end

      user = super_admin_fixture(%{username: "browser-#{suffix}"})
      {:ok, user} = Zaq.Accounts.change_password(user, %{password: "ValidPass123!"})
      {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_ip_limit: 1000})
      {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
      send(Config, :refresh)
      _ = :sys.get_state(Config)
      owner = self()

      expect(PeopleAuthDeliveryMock, :send_reply, 6, fn outgoing, _ ->
        [_, code] = Regex.run(~r/\*\*([0-9]{4}-[0-9]{4})\*\*/, outgoing.body)
        send(owner, {:delivered, code})
        :ok
      end)

      server = start_supervised!({Bandit, plug: ZaqWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      executable = System.find_executable("node") || flunk("Node.js is required")

      browser =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "test/e2e/support/people-auth-browser.cjs",
            "http://localhost:#{port}",
            engine,
            suffix,
            user.username
          ]
        ])

      result = browser_result(browser, "")
      assert result =~ "#{engine}: 390px passed"
      assert result =~ "#{engine}: 1280px passed"
      IO.puts(String.trim(result))
    end
  end

  defp browser_result(port, output, buffer \\ "") do
    receive do
      {:delivered, code} ->
        Port.command(port, code <> "\n")
        browser_result(port, output, buffer)

      {^port, {:data, data}} ->
        lines = String.split(buffer <> data, "\n")
        Enum.each(Enum.drop(lines, -1), &browser_checkpoint(port, &1))
        browser_result(port, output <> data, List.last(lines))

      {^port, {:exit_status, 0}} ->
        output

      {^port, {:exit_status, status}} ->
        flunk("Browser exited #{status}: #{output}")
    after
      60_000 ->
        Port.close(port)
        flunk("Browser journey timed out: #{output}")
    end
  end

  defp browser_checkpoint(port, "advance-resend:" <> id) do
    # Sandbox-only synchronization: age the named issued row, leaving its actual
    # expiry valid. The browser separately advances its signed display deadline.
    Zaq.Repo.get!(PersonLoginChallenge, id)
    |> PersonLoginChallenge.changeset(%{
      inserted_at: DateTime.add(DateTime.utc_now(:second), -60)
    })
    |> Zaq.Repo.update!()

    Port.command(port, "resend-ready\n")
  end

  defp browser_checkpoint(_port, _line), do: :ok
end
