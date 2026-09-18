defmodule Zaq.Engine.PeopleAuthGateway do
  @moduledoc """
  Fixed People authentication operations at the Engine boundary.

  Login identity is a delivery target, never an authenticated actor. Requesting a
  challenge composes read-only matching, quota-backed issuance and the existing
  notification fallback path. No transaction spans remote delivery. Failed sends
  invalidate only their own challenge; stale successful sends cannot select a
  superseded challenge. Only descriptors leave this orchestration.

  Authenticated profile and credential operations delegate to their focused Engine
  services, which own authorization, persistence orchestration and safe projection.
  """

  alias Jido.Action.Error
  alias Zaq.Accounts.{People, PeopleAuth}
  alias Zaq.Agent.Tools.People.NotifyPerson
  alias Zaq.Engine.{PeopleCredentials, PeopleProfile}
  require Logger

  @spec request_challenge(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_challenge(email, ip, opts \\ []) do
    with {:ok, person} <-
           People.match_person(%{email: email, platform: "email", channel_id: email}),
         {:ok, challenge} <- PeopleAuth.issue_challenge(person, ip, opts) do
      deliver(person.id, challenge, opts)
    else
      {:error, reason} when reason in [:not_found, :ineligible] ->
        {:error, :failed_identification}

      {:error, {:resend_limited, retry_after}} ->
        {:error, {:resend_limited, retry_after}}

      _ ->
        {:error, :request_unavailable}
    end
  end

  @doc "Executes a fixed auth operation; callers must use confidential event envelopes."
  @spec dispatch(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(request, opts) do
    case request do
      %{op: :request_challenge, email: email, ip: ip} ->
        request_challenge(email, ip, opts)

      %{op: :verify, challenge_id: id, code: code} ->
        PeopleAuth.verify_challenge(id, code, opts)

      %{op: :authenticate, token: token} ->
        PeopleAuth.authenticate(token, opts)

      %{op: :revoke, token: token} ->
        PeopleAuth.revoke_session(token)

      %{op: op}
      when op in [
             :profile,
             :update_self_profile,
             :update_self_channel_weight,
             :update_self_channel_order
           ] ->
        PeopleProfile.dispatch(request, opts)

      %{op: op}
      when op in [
             :list_self_credentials,
             :get_self_credential,
             :put_self_credential,
             :revoke_self_credential,
             :remove_self_credential,
             :start_self_credential_oauth,
             :reconnect_self_credential_oauth
           ] ->
        PeopleCredentials.dispatch(request, opts)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp deliver(person_id, challenge, opts) do
    result = send_challenge(person_id, challenge, opts)

    case result do
      {:ok, descriptor} ->
        {:ok, descriptor}

      _ ->
        PeopleAuth.invalidate_challenge(challenge.challenge_id)
        {:error, :delivery_failed}
    end
  end

  defp send_challenge(person_id, challenge, opts) do
    <<first::binary-size(4), last::binary-size(4)>> = challenge.code

    params = %{
      person: %{id: person_id},
      subject: "Your ZAQ sign-in code",
      message:
        "Your ZAQ sign-in code is\n\n**#{first}-#{last}**\n\nDo not share this code.\n\n*Input this code in the current Sign-in page*"
    }

    context = %{
      node_router: Keyword.get(opts, :node_router_module, Zaq.NodeRouter),
      event_opts: [confidential: true]
    }

    NotifyPerson
    |> Jido.Exec.run(params, context)
    |> delivery_result(challenge.challenge_id, opts)
  rescue
    error -> delivery_failure(:execution, error.__struct__, challenge.challenge_id)
  end

  # Jido.Exec documents both result envelopes. Never expose the action's echoed
  # message/content (or instructions) at the public authentication boundary.
  defp delivery_result(result, id, opts) when tuple_size(result) in [2, 3] do
    case {elem(result, 0), elem(result, 1)} do
      {:ok, %{status: :sent, notified: true}} ->
        PeopleAuth.challenge_status(id, opts)

      {:error, %Error.InvalidInputError{}} ->
        delivery_failure(:validation, Error.InvalidInputError, id)

      {:error, %Error.ExecutionFailureError{details: %{phase: :delivery}}} ->
        delivery_failure(:delivery, Error.ExecutionFailureError, id)

      {:error, %{__struct__: type}}
      when type in [Error.ExecutionFailureError, Error.TimeoutError, Error.InternalError] ->
        delivery_failure(:execution, type, id)

      _ ->
        delivery_failure(:delivery, :unknown, id)
    end
  end

  defp delivery_failure(phase, error_type, id) do
    Logger.warning(
      "[PeopleAuthGateway] challenge delivery failed phase=#{phase} error_type=#{inspect(error_type)}",
      phase: phase,
      error_type: error_type,
      challenge_id: id
    )

    {:error, :delivery_failed}
  end
end
