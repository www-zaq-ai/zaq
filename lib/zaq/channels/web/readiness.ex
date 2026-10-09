defmodule Zaq.Channels.Web.Readiness do
  @moduledoc """
  Closed, secret-free adapter readiness response contract and ingress projection.

  This pure boundary validates observations, reconciles desired connector settings
  with installed values, and projects them for the existing ingress status event.
  Transport probing and effective-setting resolution belong to the external adapter.
  """

  alias Zaq.ConnectorConfig.WidgetSettings

  @checks [:runtime, :transport, :delivery, :authentication, :cookie_policy]
  @fields [:protocol_version, :status, :reason, :checks, :effective_settings]
  @settings [:identity_issuer, :identity_audience, :same_site]
  @priority [:unavailable, :unknown, :starting, :ready]
  @reasons %{
    runtime: [:runtime_not_registered, :runtime_unresponsive, :runtime_starting],
    transport: [:transport_not_listening, :transport_starting, :transport_unverifiable],
    delivery: [:pubsub_unavailable],
    authentication: [:identity_not_configured, :identity_settings_mismatch],
    cookie_policy: [
      :cookie_policy_unsupported,
      :cookie_policy_mismatch,
      :secure_cookie_required,
      :https_required
    ]
  }
  @unknown [:transport_unverifiable, :cookie_policy_unsupported, :check_timeout, :check_failed]
  @starting [:runtime_starting, :transport_starting]

  @doc "Rejects unknown fields and inconsistent or private adapter observations."
  @spec validate(term()) :: {:ok, map()} | {:error, :invalid_readiness_response}
  def validate(response) do
    if valid_response?(response),
      do: {:ok, response},
      else: {:error, :invalid_readiness_response}
  end

  @doc "Projects a validated response and flags unapplied desired connector settings."
  @spec project(map(), map()) :: map()
  def project(response, desired) do
    checks = reconcile(response.checks, response.effective_settings, desired)
    {state, reason} = aggregate(checks)

    %{
      status: ingress_state(state),
      mode: "websocket",
      summary: summary(state, reason),
      reason: reason,
      checks: checks,
      effective_settings: response.effective_settings
    }
  end

  @doc "Returns a safe unknown result when adapter readiness cannot be established."
  @spec unknown(atom()) :: map()
  def unknown(reason) when reason in [:readiness_unsupported, :check_timeout, :check_failed] do
    %{
      status: :unknown,
      mode: "websocket",
      reason: reason,
      summary: summary(:unknown, reason),
      effective_settings: Map.new(@settings, &{&1, %{value: nil, source: :unresolved}})
    }
  end

  defp valid_response?(response) do
    exact_keys?(response, @fields) and response.protocol_version == 1 and
      valid_checks?(response.checks) and valid_settings?(response.effective_settings) and
      resolved_ready_checks?(response) and
      aggregate(response.checks) == {response.status, response.reason}
  end

  defp valid_checks?(checks) do
    exact_keys?(checks, @checks) and
      Enum.all?(@checks, &valid_check?(&1, Map.fetch!(checks, &1)))
  end

  defp valid_check?(name, check) do
    exact_keys?(check, [:status, :reason]) and
      valid_check_state?(check.status, check.reason, name)
  end

  defp valid_check_state?(:ready, nil, _name), do: true

  defp valid_check_state?(state, reason, name) do
    reason in (Map.fetch!(@reasons, name) ++ [:check_timeout, :check_failed]) and
      state == reason_state(reason)
  end

  defp reason_state(reason) when reason in @unknown, do: :unknown
  defp reason_state(reason) when reason in @starting, do: :starting
  defp reason_state(_reason), do: :unavailable

  defp valid_settings?(settings) do
    exact_keys?(settings, @settings) and
      Enum.all?(@settings, &valid_setting?(&1, Map.fetch!(settings, &1)))
  end

  defp valid_setting?(name, setting) do
    exact_keys?(setting, [:value, :source]) and valid_setting_value?(name, setting)
  end

  defp valid_setting_value?(_name, %{value: nil, source: :unresolved}), do: true

  defp valid_setting_value?(name, %{value: value, source: source}) do
    sources = if name == :same_site, do: [:endpoint], else: []

    source in ([:connector, :application, :default] ++ sources) and
      WidgetSettings.validate(%{Atom.to_string(name) => value}) == :ok
  end

  defp resolved_ready_checks?(response) do
    resolved_check?(response, :authentication, [:identity_issuer, :identity_audience]) and
      resolved_check?(response, :cookie_policy, [:same_site])
  end

  defp resolved_check?(response, check, settings) do
    response.checks[check].status != :ready or
      Enum.all?(settings, &(response.effective_settings[&1].source != :unresolved))
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp aggregate(checks) do
    state =
      Enum.find(@priority, fn state -> Enum.any?(@checks, &(checks[&1].status == state)) end)

    check = Enum.find(@checks, &(checks[&1].status == state))
    {state, checks[check].reason}
  end

  defp reconcile(checks, effective, desired) do
    checks
    |> mismatch(effective, desired, :authentication, [:identity_issuer, :identity_audience])
    |> mismatch(effective, desired, :cookie_policy, [:same_site])
  end

  defp mismatch(checks, effective, desired, check, settings) do
    changed? =
      Enum.any?(settings, fn key ->
        actual = effective[key].value
        requested = Map.get(desired, Atom.to_string(key))
        not is_nil(requested) and not is_nil(actual) and requested != actual
      end)

    if changed? do
      reason =
        if check == :authentication,
          do: :identity_settings_mismatch,
          else: :cookie_policy_mismatch

      Map.put(checks, check, %{status: :unavailable, reason: reason})
    else
      checks
    end
  end

  defp ingress_state(:ready), do: :ok
  defp ingress_state(:starting), do: :pending
  defp ingress_state(:unavailable), do: :error
  defp ingress_state(:unknown), do: :unknown

  defp summary(:ready, _reason), do: "Ready to receive connections"
  defp summary(:starting, _reason), do: "Widget transport is starting"
  defp summary(:unknown, :readiness_unsupported), do: "Adapter does not support readiness checks"

  defp summary(:unknown, :cookie_policy_unsupported),
    do: "Applied cookie policy cannot be verified"

  defp summary(:unknown, :check_timeout), do: "Readiness check timed out"
  defp summary(:unknown, _reason), do: "Widget readiness cannot be verified"
  defp summary(:unavailable, :identity_settings_mismatch), do: "JWT settings are not applied"
  defp summary(:unavailable, :cookie_policy_mismatch), do: "Cookie policy is not applied"

  defp summary(:unavailable, :identity_not_configured),
    do: "Widget authentication is not configured"

  defp summary(:unavailable, :https_required), do: "Cookie policy requires HTTPS"
  defp summary(:unavailable, :secure_cookie_required), do: "Cookie policy requires Secure cookies"
  defp summary(:unavailable, _reason), do: "Widget is unavailable to receive connections"
end
