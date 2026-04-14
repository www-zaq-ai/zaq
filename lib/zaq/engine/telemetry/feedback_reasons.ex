defmodule Zaq.Engine.Telemetry.FeedbackReasons do
  @moduledoc "Canonical negative feedback reasons used across BO telemetry surfaces."

  @reasons [
    "Not factually correct",
    "Too slow",
    "Outdated information",
    "Did not follow my request",
    "Missing information in knowledge base"
  ]

  @spec list() :: [String.t()]
  def list, do: @reasons
end
