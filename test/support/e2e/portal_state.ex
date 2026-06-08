defmodule Zaq.E2E.PortalState do
  @moduledoc false

  use Agent

  defstruct emails: MapSet.new(), fingerprints: MapSet.new(), offline: false

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  @doc """
  Pre-register a conflicting email or machine fingerprint.
  Pass `email:` and/or `fingerprint:` as keyword args.
  The next `portal_onboard` call carrying that value returns a real 409.
  """
  def register_conflict(opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> maybe_add_email(Keyword.get(opts, :email))
      |> maybe_add_fingerprint(Keyword.get(opts, :fingerprint))
    end)
  end

  @doc "Returns true when the given email is pre-registered as conflicting."
  def conflict_email?(email) when is_binary(email) do
    Agent.get(__MODULE__, fn %{emails: s} -> MapSet.member?(s, email) end)
  end

  @doc "Returns true when the given fingerprint is pre-registered as conflicting."
  def conflict_fingerprint?(fp) when is_binary(fp) do
    Agent.get(__MODULE__, fn %{fingerprints: s} -> MapSet.member?(s, fp) end)
  end

  @doc "Puts the stub into offline mode. The metadata endpoint returns 503."
  def set_offline(offline) when is_boolean(offline) do
    Agent.update(__MODULE__, fn state -> %{state | offline: offline} end)
  end

  @doc "Returns true when the stub is in offline mode."
  def offline? do
    Agent.get(__MODULE__, fn %{offline: offline} -> offline end)
  end

  @doc "Clears all registered conflicts and resets offline mode. Called by Reset.run()."
  def reset do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)
  end

  defp maybe_add_email(state, nil), do: state
  defp maybe_add_email(state, email), do: %{state | emails: MapSet.put(state.emails, email)}

  defp maybe_add_fingerprint(state, nil), do: state

  defp maybe_add_fingerprint(state, fp),
    do: %{state | fingerprints: MapSet.put(state.fingerprints, fp)}
end
