defmodule ZaqWeb.Live.People.AuthHook do
  @moduledoc """
  Revalidates current People identity/grants on mount, reconnect and every event.
  The bearer is retained only in the server-private hook closure, never assigns.
  Cookie session is supplied by LiveView connect_info, not a signed DOM payload.
  """
  import Phoenix.Component
  import Phoenix.LiveView
  alias Zaq.Engine.Events

  def on_mount(:public, _params, _session, socket) do
    if Zaq.NodeRoles.has_any?([:channels]),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: "/people/login")}
  end

  def on_mount(:default, _params, session, socket) do
    token = session["person_session_token"]

    case authenticate(socket, token) do
      {:cont, socket} ->
        {:cont,
         attach_hook(socket, :person_authority, :handle_event, fn _, _, socket ->
           authenticate(socket, token)
         end)}

      halt ->
        halt
    end
  end

  defp authenticate(socket, token) do
    result =
      if Zaq.NodeRoles.has_any?([:channels]) do
        Events.build_and_dispatch_invoke_event(
          %{op: :authenticate, token: token},
          :people_auth,
          event_opts: [confidential: true]
        ).response
      else
        {:error, :unavailable}
      end

    case result do
      {:ok, %{person: person, permissions: permissions, session: session}} ->
        {:cont,
         assign(socket,
           current_person: person,
           person_permissions: permissions,
           person_session: session
         )}

      _ ->
        {:halt, redirect(socket, to: "/people/login")}
    end
  end
end
