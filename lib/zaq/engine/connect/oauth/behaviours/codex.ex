defmodule Zaq.Engine.Connect.OAuth.Behaviours.Codex do
  @moduledoc """
  OpenAI Codex/ChatGPT OAuth2 protocol customizations.

  Account claims are reduced to the one non-secret identifier used by ZAQ. Raw ID
  tokens and arbitrary provider response fields remain transient.
  """

  @behaviour Zaq.Engine.Connect.OAuth.Behaviour

  @redirect_uri "http://localhost:1455/auth/callback"

  @impl true
  def redirect_uri(_credential, _default_uri), do: @redirect_uri

  @impl true
  def pkce_required?(_credential), do: true

  @impl true
  def authorize_params(_credential) do
    %{
      "originator" => "zaqos",
      "id_token_add_organizations" => "true",
      "codex_cli_simplified_flow" => "true"
    }
  end

  @impl true
  def normalize_token_payload(payload) do
    account_id = chatgpt_account_id(payload)
    payload = Map.drop(payload, [:id_token, "id_token"])

    case account_id do
      account_id when is_binary(account_id) and account_id != "" ->
        metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
        Map.put(payload, :metadata, Map.put(metadata, "chatgpt_account_id", account_id))

      _ ->
        payload
    end
  end

  @impl true
  def valid_grant_metadata?(metadata) when is_map(metadata) do
    Enum.all?(metadata, fn
      {"chatgpt_account_id", value} -> is_binary(value) and value != ""
      _ -> false
    end)
  end

  def valid_grant_metadata?(_), do: false

  @impl true
  def runtime_identity(metadata) when is_map(metadata) do
    case Map.get(metadata, "chatgpt_account_id") do
      value when is_binary(value) and value != "" and byte_size(value) <= 255 ->
        %{"chatgpt_account_id" => value}

      _ ->
        %{}
    end
  end

  def runtime_identity(_), do: %{}

  defp chatgpt_account_id(payload) do
    payload
    |> account_tokens()
    |> Enum.find_value(&account_id_from_token/1)
  end

  defp account_tokens(payload) do
    [
      Map.get(payload, :id_token) || Map.get(payload, "id_token"),
      Map.get(payload, :access_token) || Map.get(payload, "access_token")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp account_id_from_token(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      claims["chatgpt_account_id"] ||
        get_in(claims, ["https://api.openai.com/auth", "chatgpt_account_id"]) ||
        get_in(claims, ["organizations", Access.at(0), "id"])
    else
      _ -> nil
    end
  end
end
