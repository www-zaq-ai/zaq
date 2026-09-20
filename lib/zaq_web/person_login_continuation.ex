defmodule ZaqWeb.PersonLoginContinuation do
  @moduledoc """
  Owns the signed-session continuation policy for People page authentication.

  Only canonical, protected People page routes are retained. Authentication and
  destination authorization remain the responsibility of their existing layers.
  """

  import Plug.Conn

  @session_key :person_login_return_to
  @default_destination "/people/profile"
  @static_destinations MapSet.new([
                         @default_destination,
                         "/people/credentials",
                         "/people/history"
                       ])

  @doc "Stores the current protected GET page when it is an eligible destination."
  @spec remember(Plug.Conn.t()) :: Plug.Conn.t()
  def remember(%Plug.Conn{method: method} = conn) when method in ["GET", "HEAD"] do
    conn = delete_session(conn, @session_key)
    destination = "/" <> Enum.join(conn.path_info, "/")

    case validate(destination) do
      {:ok, destination} -> put_session(conn, @session_key, destination)
      :error -> conn
    end
  end

  def remember(conn), do: delete_session(conn, @session_key)

  @doc "Consumes a valid destination, falling back to the People profile."
  @spec pop(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def pop(conn) do
    destination = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    case validate(destination) do
      {:ok, destination} -> {conn, destination}
      :error -> {conn, @default_destination}
    end
  end

  @doc "Clears any pending People login continuation."
  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn), do: delete_session(conn, @session_key)

  @doc "Builds a local path using the current deployment script-name prefix."
  @spec prefixed_path(Plug.Conn.t(), String.t()) :: String.t()
  def prefixed_path(conn, path),
    do: Phoenix.VerifiedRoutes.unverified_path(conn, ZaqWeb.Router, path)

  @doc "Validates a canonical local People portal page destination."
  @spec validate(term()) :: {:ok, String.t()} | :error
  def validate(destination) when is_binary(destination) do
    cond do
      MapSet.member?(@static_destinations, destination) ->
        {:ok, destination}

      valid_conversation_destination?(destination) ->
        {:ok, destination}

      true ->
        :error
    end
  end

  def validate(_destination), do: :error

  defp valid_conversation_destination?(destination) do
    case String.split(destination, "/", trim: true) do
      ["people", "conversations", id] ->
        destination == "/people/conversations/" <> id and Ecto.UUID.cast(id) == {:ok, id}

      _ ->
        false
    end
  end
end
