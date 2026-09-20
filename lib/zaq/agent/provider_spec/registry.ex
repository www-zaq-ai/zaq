defmodule Zaq.Agent.ProviderSpec.Registry do
  @moduledoc "Static provider-to-runtime implementation registry."

  alias Zaq.Agent.ProviderSpec.Providers.{Codex, Default}

  @implementations [Default, Codex]

  @spec fetch(term()) :: module()
  def fetch(provider) when provider in ["openai_codex", :openai_codex], do: Codex
  def fetch(_provider), do: Default

  @spec implementations() :: [module()]
  def implementations, do: @implementations
end
