defmodule ZaqWeb.PeopleBrowserTest do
  use ZaqWeb.ConnCase, async: false
  @moduletag :real_browser

  import Mox
  alias Zaq.Accounts.{People, PeoplePermissions}
  alias Zaq.Channels.PeopleAuthDeliveryMock
  alias Zaq.Channels.PeopleAuthRateLimiter.Config
  alias Zaq.TestSupport.PeopleAuthDelivery
  import Zaq.AccountsFixtures

  setup :verify_on_exit!

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 180_000
    test "#{engine}: mobile/desktop sign-in, resend and independent BO/People logout" do
      engine = unquote(engine)
      suffix = "#{engine}-#{System.unique_integer([:positive])}"
      PeopleAuthDelivery.setup()
      set_mox_global()

      for width <- [390, 1280] do
        {:ok, _} =
          People.create_person(%{
            full_name: "Browser Person",
            email: "#{suffix}-#{width}@example.test"
          })
      end

      user = super_admin_fixture(%{username: "browser-#{suffix}"})
      {:ok, user} = Zaq.Accounts.change_password(user, %{password: "ValidPass123!"})
      {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_ip_limit: 1000})
      {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
      send(Config, :refresh)
      _ = :sys.get_state(Config)
      owner = self()

      expect(PeopleAuthDeliveryMock, :send_reply, 6, fn outgoing, _ ->
        [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, outgoing.body)
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

  defp browser_result(port, output) do
    receive do
      {:delivered, code} ->
        Port.command(port, code <> "\n")
        browser_result(port, output)

      {^port, {:data, data}} ->
        browser_result(port, output <> data)

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
end
