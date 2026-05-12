defmodule Zaq.Workflows.Conditions.NoEmails do
  @moduledoc "Passes when the `emails` list in the fact map is empty."

  @behaviour Zaq.Workflows.Step

  @impl true
  def call(fact) do
    emails = Map.get(fact, :emails) || Map.get(fact, "emails") || []
    emails == []
  end

  @impl true
  def name, do: "no_emails"

  @impl true
  def description, do: "Continues when no emails were fetched."
end
