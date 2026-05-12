defmodule Zaq.Workflows.Conditions.EmailsFound do
  @moduledoc "Passes when the `emails` list in the fact map is non-empty."

  @behaviour Zaq.Workflows.Step

  @impl true
  def call(fact) do
    emails = Map.get(fact, :emails) || Map.get(fact, "emails") || []
    emails != []
  end

  @impl true
  def name, do: "emails_found"

  @impl true
  def description, do: "Continues when at least one email was fetched."
end
