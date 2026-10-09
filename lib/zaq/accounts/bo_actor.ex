defmodule Zaq.Accounts.BOActor do
  @moduledoc "Validates a trusted BO actor against the current user record."

  alias Zaq.Accounts

  @doc "Returns the current enabled BO user and rejects missing, deleted, or password-blocked actors."
  def current_user(actor, opts \\ [])

  def current_user(actor, opts) when is_map(actor) and is_list(opts) do
    user_id = Map.get(actor, :user_id) || Map.get(actor, "user_id")
    allow_password_change? = Keyword.get(opts, :allow_password_change, false)

    case user_id && Accounts.get_user(user_id) do
      %{must_change_password: value} = user when not value or allow_password_change? ->
        {:ok, user}

      _ ->
        {:error, :unauthorized}
    end
  end

  def current_user(_actor, _opts), do: {:error, :unauthorized}
end
