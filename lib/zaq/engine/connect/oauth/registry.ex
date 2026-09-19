defmodule Zaq.Engine.Connect.OAuth.Registry do
  @moduledoc """
  Static allowlist of OAuth behavior implementations available to administrators.

  Stable string IDs are persisted in credential metadata. Module names never cross
  the UI or event boundary and cannot be supplied dynamically.
  """

  alias Zaq.Engine.Connect.OAuth.Behaviours.{Codex, Standard}

  @entries [
    %{
      id: "standard",
      title: "Standard OAuth2",
      description: "Standards-compliant OAuth2 authorization, exchange, and refresh.",
      module: Standard
    },
    %{
      id: "openai_chatgpt_codex",
      title: "OpenAI Codex / ChatGPT",
      description: "ChatGPT subscription OAuth2 with Codex redirect, PKCE, and account metadata.",
      module: Codex
    }
  ]

  @spec entries() :: [map()]
  def entries, do: @entries

  @spec public_entries() :: [map()]
  def public_entries, do: Enum.map(@entries, &Map.delete(&1, :module))

  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :unsupported_oauth_behaviour}
  def fetch(profile) when profile in [nil, ""], do: {:ok, Standard}

  def fetch(profile) when is_binary(profile) do
    case Enum.find(@entries, &(&1.id == profile)) do
      %{module: module} -> {:ok, module}
      nil -> {:error, :unsupported_oauth_behaviour}
    end
  end

  def fetch(_), do: {:error, :unsupported_oauth_behaviour}

  @spec registered?(String.t() | nil) :: boolean()
  def registered?(profile), do: match?({:ok, _}, fetch(profile))
end
