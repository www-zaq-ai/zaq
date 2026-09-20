defmodule ZaqWeb.Plugs.PersonAuth do
  @moduledoc "Authenticates People HTTP requests independently of BO user credentials."
  import Plug.Conn
  import Phoenix.Controller
  alias Zaq.Engine.Events
  alias ZaqWeb.PersonLoginContinuation

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

      {:error, :invalid_session} ->
        conn
        |> delete_session(:person_session_token)
        |> redirect_to_login()
        |> halt()

      _ ->
        conn
        |> put_flash(:error, "People sign-in is unavailable. Please try again.")
        |> redirect_to_login()
        |> halt()
    end
  end

  defp redirect_to_login(conn) do
    conn = PersonLoginContinuation.remember(conn)
    redirect(conn, to: PersonLoginContinuation.prefixed_path(conn, "/people/login"))
  end
end
