defmodule ZaqWeb.DeviceCredentialsBrowserTest do
  use ZaqWeb.ConnCase, async: false
  @moduletag :real_browser
  import Mox
  import Zaq.AccountsFixtures
  import Ecto.Query
  alias Zaq.Accounts.{People, PeoplePermissions}
  alias Zaq.Channels.PeopleAuthDeliveryMock
  alias Zaq.Engine.Connect.{DeviceAttempt, Grant}
  alias Zaq.Repo
  alias Zaq.TestSupport.{DeviceBrowserHTTP, PeopleAuthDelivery}

  setup :verify_on_exit!

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 240_000
    test "#{engine}: both device modals at mobile and desktop widths" do
      engine = unquote(engine)
      start_supervised!(DeviceBrowserHTTP)
      original = Application.fetch_env(:zaq, :connect_oauth_http_client)
      Application.put_env(:zaq, :connect_oauth_http_client, DeviceBrowserHTTP)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:zaq, :connect_oauth_http_client, value)
          :error -> Application.delete_env(:zaq, :connect_oauth_http_client)
        end
      end)

      PeopleAuthDelivery.setup()
      set_mox_global()
      {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
      {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
      {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_ip_limit: 1000})
      suffix = "#{engine}-#{System.unique_integer([:positive])}"
      user = super_admin_fixture(%{username: "device-#{suffix}"})
      {:ok, user} = Zaq.Accounts.change_password(user, %{password: "ValidPass123!"})
      owner = self()

      expect(PeopleAuthDeliveryMock, :send_reply, 2, fn outgoing, _ ->
        [_, code] = Regex.run(~r/\*\*([0-9]{4}-[0-9]{4})\*\*/, outgoing.body)
        send(owner, {:delivered, code})
        :ok
      end)

      fixtures =
        for width <- [390, 1280] do
          {:ok, person} =
            People.create_person(%{
              full_name: "Device Browser",
              email: "#{suffix}-#{width}@example.test"
            })

          {:ok, credential} =
            Zaq.System.create_ai_provider_credential(%{
              name: "Device #{suffix}-#{width}",
              provider: "openai_codex",
              endpoint: "https://chatgpt.com/backend-api",
              auth_kind: "oauth2",
              personal_credential_policy: "required",
              metadata: %{
                "auth_profile" => "openai_chatgpt_codex",
                "client_id" => "browser-client",
                "token_url" => "https://auth.openai.com/oauth/token"
              }
            })

          %{
            width: width,
            person_id: person.id,
            email: person.email,
            ai_id: credential.id,
            connect_id: credential.connect_credential_id
          }
        end

      server = start_supervised!({Bandit, plug: ZaqWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      :ok = Zaq.System.set_global_base_url("http://localhost:#{port}")

      browser =
        Port.open({:spawn_executable, System.find_executable("node")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "test/e2e/support/device-credentials-browser.cjs",
            "http://localhost:#{port}",
            engine,
            user.username,
            Jason.encode!(fixtures)
          ]
        ])

      on_exit(fn ->
        if Port.info(browser), do: Port.close(browser)
      end)

      output = browser_result(browser, "")
      assert output =~ "#{engine}: 390px passed"
      assert output =~ "#{engine}: 1280px passed"

      for fixture <- fixtures do
        assert Repo.get_by!(Grant, credential_id: fixture.connect_id, owner_type: "org").access_token ==
                 "BROWSER-ACCESS-SECRET"

        assert Repo.get_by!(Grant,
                 credential_id: fixture.connect_id,
                 owner_type: "person",
                 owner_id: fixture.person_id
               ).access_token == "BROWSER-ACCESS-SECRET"
      end

      IO.puts(String.trim(output))
    end
  end

  defp browser_result(port, output, buffer \\ "") do
    receive do
      {:delivered, code} ->
        Port.command(port, code <> "\n")
        browser_result(port, output, buffer)

      {^port, {:data, data}} ->
        lines = String.split(buffer <> data, "\n")
        Enum.each(Enum.drop(lines, -1), &checkpoint(port, &1))
        browser_result(port, output <> data, List.last(lines))

      {^port, {:exit_status, 0}} ->
        output

      {^port, {:exit_status, status}} ->
        flunk("Device browser exited #{status}: #{output}")
    after
      90_000 ->
        Port.close(port)
        flunk("Device browser timed out: #{output}")
    end
  end

  defp checkpoint(port, "device-checkpoint:" <> json) do
    %{"action" => action, "credential_id" => id, "owner_type" => type} = Jason.decode!(json)

    attempt =
      Repo.one!(
        from a in DeviceAttempt,
          where: a.credential_id == ^id and a.owner_type == ^type,
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: 1
      )

    case action do
      "expire" ->
        Repo.update!(
          Ecto.Changeset.change(attempt, expires_at: DateTime.add(DateTime.utc_now(), -1))
        )

      "interrupt" ->
        pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

      "approve" ->
        material = Jason.decode!(attempt.device_material)
        DeviceBrowserHTTP.approve(material["device_auth_id"])
    end

    Port.command(port, "checkpoint-ready\n")
  end

  defp checkpoint(_, _), do: :ok
end
