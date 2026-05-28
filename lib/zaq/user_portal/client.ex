defmodule Zaq.UserPortal.Client do
  @moduledoc """
  HTTP client for the Zaq User Portal API.

  Handles user provisioning via POST /onboarding, which creates the user
  in LiteLLM and returns their API key.

  ## Testing

  In `config/test.exs`, configure Req.Test stubbing:

      config :zaq, Zaq.UserPortal.Client,
        req_options: [plug: {Req.Test, Zaq.UserPortal.Client}]

  Then in tests, use `Req.Test.stub/2` to mock responses.
  """

  alias Zaq.System.MachineFingerprint

  require Logger

  @spec onboard_user(String.t()) ::
          {:ok, %{litellm_api_key: String.t()}} | {:error, term()}
  def onboard_user(email) when is_binary(email) do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)
    fingerprint = MachineFingerprint.get()

    req_opts =
      [
        url: base_url <> "/onboarding",
        json: %{email: email, machine_fingerprint: fingerprint, plan: "free"}
      ]
      |> Keyword.merge(req_options())

    case Req.post(req_opts) do
      {:ok, %{status: 200, body: %{"user" => %{"litellm_api_key" => key}}}}
      when is_binary(key) ->
        {:ok, %{litellm_api_key: key}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("User portal onboarding returned #{status}: #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.warning("User portal onboarding HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp req_options do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
