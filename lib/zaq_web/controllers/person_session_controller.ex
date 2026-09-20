defmodule ZaqWeb.PersonSessionController do
  @moduledoc """
  CSRF-protected HTTP bridge for People sign-in and the existing HttpOnly cookie
  session. Bearers stay in Plug.Session, never in LiveView assigns or URLs.
  Login/resend use ordinary POST/redirect forms; no asynchronous UI result can
  select an older challenge. Engine remains authoritative for concurrent requests.
  """
  use ZaqWeb, :controller

  alias Zaq.Channels.PeopleAuth
  alias Zaq.Config
  alias Zaq.Engine.Events
  alias Zaq.NodeRouter
  alias ZaqWeb.PersonLoginContinuation

  def request(conn, params) do
    email = Map.get(params, "email", get_session(conn, :person_login_email))

    case PeopleAuth.request_challenge(email, conn.remote_ip) do
      {:ok, %{challenge_id: _, expires_at: _} = challenge} ->
        conn
        |> put_session(:person_login_email, email)
        |> put_session(:person_login_challenge, challenge)
        |> redirect_to_login()

      {:error, {:resend_limited, _}} when not is_map_key(params, "email") ->
        conn
        |> put_flash(:error, "Please wait before requesting another code.")
        |> redirect_to_login()

      error ->
        conn
        |> put_flash(:error, request_error_message(error))
        |> redirect_to_login()
    end
  end

  def create(conn, params) do
    id = Map.get(params, "challenge_id")

    case auth(%{op: :verify, challenge_id: id, code: Map.get(params, "code")}, conn) do
      {:ok, %{token: token}} ->
        conn =
          conn
          |> configure_session(renew: true)
          |> put_session(:person_session_token, token)
          |> delete_session(:person_login_challenge)
          |> delete_session(:person_login_email)

        {conn, destination} = PersonLoginContinuation.pop(conn)
        redirect(conn, to: PersonLoginContinuation.prefixed_path(conn, destination))

      _ ->
        conn
        |> retain_challenge(id)
        |> put_flash(
          :error,
          "The code is incorrect or has expired. Try again or request a new code."
        )
        |> redirect_to_login()
    end
  end

  def delete(conn, _params) do
    result = safe_revoke(conn)

    conn =
      conn
      |> delete_session(:person_session_token)
      |> delete_session(:person_login_challenge)
      |> delete_session(:person_login_email)
      |> PersonLoginContinuation.clear()
      |> configure_session(renew: true)

    conn =
      case result do
        {:ok, _} -> conn
        {:error, :invalid_session} -> conn
        _ -> put_flash(conn, :error, "Signed out here. Server revocation could not be confirmed.")
      end

    redirect_to_login(conn)
  end

  defp request_error_message({:error, :failed_identification}),
    do: "We couldn't start the authentication process for this address."

  defp request_error_message({:error, :delivery_failed}),
    do: "We couldn't send your verification code. Please try again later."

  defp request_error_message(_),
    do: "Unable to send a sign-in code. Please try again later."

  defp retain_challenge(conn, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        challenge = get_session(conn, :person_login_challenge)

        challenge =
          if challenge && challenge.challenge_id == id,
            do: challenge,
            else: %{challenge_id: id, expires_at: nil}

        put_session(conn, :person_login_challenge, challenge)

      _ ->
        conn
    end
  end

  defp retain_challenge(conn, _), do: conn

  defp safe_revoke(conn) do
    auth(%{op: :revoke, token: get_session(conn, :person_session_token)}, conn)
  rescue
    _ -> {:error, :revocation_unavailable}
  catch
    :exit, _ -> {:error, :revocation_unavailable}
  end

  defp auth(request, conn) do
    router =
      Config.get(:zaq, :person_session_controller_node_router_module, NodeRouter,
        config: conn.assigns[:config]
      )

    Events.build_and_dispatch_invoke_event(request, :people_auth,
      event_opts: [confidential: true],
      node_router: router
    ).response
  end

  defp redirect_to_login(conn),
    do: redirect(conn, to: PersonLoginContinuation.prefixed_path(conn, "/people/login"))
end
