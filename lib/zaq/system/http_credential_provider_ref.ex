defmodule Zaq.System.HttpCredentialProviderRef do
  @moduledoc """
  Parser and formatter for dynamic outbound HTTP credential provider references.

  Existing Auth Credentials store provider identity as a string. Dynamic HTTP
  providers use the reserved `http:<id>` namespace so the current credential
  contract can remain unchanged while provider definitions move to BO-managed
  rows.
  """

  @prefix "http:"

  @type parsed :: {:http, pos_integer()} | {:static, String.t()}

  @doc "Builds the canonical provider string for a dynamic HTTP provider id."
  @spec format(pos_integer() | String.t()) ::
          {:ok, String.t()} | {:error, :invalid_http_provider_id}
  def format(id) do
    with {:ok, id} <- parse_id(id), do: {:ok, @prefix <> Integer.to_string(id)}
  end

  @doc "Parses a provider string into either a static name or dynamic HTTP id."
  @spec parse(term()) :: {:ok, parsed()} | {:error, atom()}
  def parse(provider) when is_binary(provider) do
    provider = String.trim(provider)

    cond do
      provider == "" ->
        {:error, :invalid_provider_ref}

      String.starts_with?(provider, @prefix) ->
        provider
        |> String.replace_prefix(@prefix, "")
        |> parse_id()
        |> case do
          {:ok, id} -> {:ok, {:http, id}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, {:static, provider}}
    end
  end

  def parse(_provider), do: {:error, :invalid_provider_ref}

  @doc "Returns true when the provider string belongs to the reserved HTTP namespace."
  @spec dynamic_http?(term()) :: boolean()
  def dynamic_http?(provider) when is_binary(provider), do: String.starts_with?(provider, @prefix)
  def dynamic_http?(_provider), do: false

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_http_provider_id}
    end
  end

  defp parse_id(_id), do: {:error, :invalid_http_provider_id}

  @doc false
  def parse_id_for_validator(id), do: parse_id(id)
end
