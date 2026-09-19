defmodule ZaqWeb.PersonOAuthCallbackTest do
  use ZaqWeb.ConnCase, async: true
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.TestSupport.{OpenAIStub, PersonOAuth}

  test "Phoenix parameter filtering hides OAuth secrets before formatting logs" do
    params =
      Map.new(
        ["code", "state", "access_token", "refresh_token", "client_secret", "code_verifier"],
        &{&1, "SECRET_SENTINEL"}
      )

    filtered = Phoenix.Logger.filter_values(params)
    refute inspect(filtered) =~ "SENTINEL"
    assert Enum.all?(filtered, fn {_, value} -> value == "[FILTERED]" end)
  end

  for result <- [:success, :error] do
    test "real callback #{result} hides secrets from browser, logs and workflow stream", %{
      conn: conn
    } do
      {server, url} =
        OpenAIStub.server(
          fn _, _ ->
            case unquote(result) do
              :success ->
                {200,
                 %{"access_token" => "ACCESS_SENTINEL", "refresh_token" => "REFRESH_SENTINEL"}}

              :error ->
                {400, %{"error" => "</script>PROVIDER_SECRET_SENTINEL"}}
            end
          end,
          self()
        )

      start_supervised!(server)
      person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "OAuth callback"}))

      {:ok, dto} =
        Connect.save_credential_configuration(nil, %{
          name: "callback-#{Ecto.UUID.generate()}",
          provider: "example",
          auth_kind: "oauth2",
          secret_binding: :grant,
          personal_credential_policy: :required,
          client_id: "client",
          client_secret: "CLIENT_SECRET_SENTINEL",
          metadata: %{"authorize_url" => "https://provider.example/authorize", "token_url" => url}
        })

      {:ok, _} = PersonOAuth.associate(dto.credential_id)
      {:ok, %{authorize_url: url}} = PersonOAuth.start(person, dto.credential_id)
      state = URI.decode_query(URI.parse(url).query)["state"]
      Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          response =
            get(conn, "/channels/oauth2/example/redirect", %{
              "state" => state,
              "code" => "CODE_SENTINEL",
              "owner_id" => 99
            })

          body = html_response(response, 200)

          assert body =~
                   if(unquote(result) == :success, do: "Grant created", else: "Grant failed")

          assert body =~ "window.location.origin"
          refute body =~ ~s(}, "*")
          refute body =~ "SENTINEL"
          refute body =~ state
          assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
          assert get_resp_header(response, "cache-control") == ["no-store"]
        end)

      refute log =~ "SENTINEL"
      refute log =~ state

      refute_received {:node_router_event,
                       %Zaq.Event{request: %{args: ["example", %{"state" => ^state}]}}}
    end
  end
end
