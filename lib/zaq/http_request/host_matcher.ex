defmodule Zaq.HttpRequest.HostMatcher do
  @moduledoc """
  Matches normalized hostnames against exact and domain-suffix patterns.

  Patterns beginning with `.` match subdomains of that suffix. Other patterns
  are exact host matches.
  """

  @doc "Returns true when `host` matches `pattern`."
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(host, "." <> suffix), do: String.ends_with?(host, "." <> suffix)
  def matches?(host, pattern), do: host == pattern
end
