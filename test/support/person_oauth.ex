defmodule Zaq.TestSupport.PersonOAuth do
  @moduledoc false

  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.PeopleAuthGateway

  def start(person, credential_id, opts \\ []),
    do: dispatch(person, credential_id, :start_self_credential_oauth, opts)

  def reconnect(person, credential_id, opts \\ []),
    do: dispatch(person, credential_id, :reconnect_self_credential_oauth, opts)

  defp dispatch(person, credential_id, operation, opts) do
    with {:ok, _} <- PeoplePermissions.grant(:everyone, :access_profile),
         {:ok, _} <- PeoplePermissions.grant(:everyone, :manage_credentials),
         {:ok, token} <- session_token(person) do
      PeopleAuthGateway.dispatch(
        %{op: operation, token: token, credential_id: credential_id},
        opts
      )
    end
  end

  defp session_token(%{id: id} = person) when is_integer(id) do
    key = {__MODULE__, id}

    case Process.get(key) do
      nil ->
        with {:ok, challenge} <- PeopleAuth.issue_challenge(person, unique_ip()),
             {:ok, %{token: token}} <-
               PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code) do
          Process.put(key, token)
          {:ok, token}
        end

      token ->
        {:ok, token}
    end
  end

  defp session_token(_), do: {:error, :unauthorized}

  defp unique_ip do
    value = rem(System.unique_integer([:positive]), 16_777_216)
    <<a, b, c>> = <<value::24>>
    {127, a, b, c}
  end
end
