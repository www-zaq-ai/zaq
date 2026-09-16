defmodule ZaqWeb.Plugs.PersonAuth do
  @moduledoc "Authenticates People HTTP requests independently of BO user credentials."
  import Plug.Conn
  import Phoenix.Controller
  alias Zaq.Engine.Events

  def init(opts), do: opts

  def call(conn, _opts) do
    result =
      Events.build_and_dispatch_invoke_event(
        %{op: :authenticate, token: get_session(conn, :person_session_token)},
        :people_auth,
        event_opts: [confidential: true]
      ).response

    case result do
      {:ok, %{person: person, permissions: permissions, session: session}} ->
        conn
        |> assign(:current_person, person)
        |> assign(:person_permissions, permissions)
        |> assign(:person_session, session)

      _ ->
        conn
        |> delete_session(:person_session_token)
        |> redirect(to: "/people/login")
        |> halt()
    end
  end
end
