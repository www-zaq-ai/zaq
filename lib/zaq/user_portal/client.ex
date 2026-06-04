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

  @doc """
  Checks portal liveness then fetches onboarding metadata.

  Returns `{:ok, metadata}` only when the portal is reachable AND
  `/onboarding/free` returns a valid payload. Any failure — connection
  refused, timeout, non-200, or unexpected body — returns `:unavailable`.
  """
  @spec fetch_onboarding(String.t()) :: {:ok, map()} | :unavailable
  def fetch_onboarding(slug) do
    case check_liveness() do
      :reachable -> fetch_onboarding_metadata(slug)
      :unreachable -> :unavailable
    end
  end

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

  defp check_liveness do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)

    req_opts =
      [url: base_url <> "/health/liveliness", receive_timeout: 3_000, retry: false]
      |> Keyword.merge(req_options())

    case Req.get(req_opts) do
      {:ok, %{status: 200}} -> :reachable
      _ -> :unreachable
    end
  end

  defp fetch_onboarding_metadata(slug) do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)

    req_opts =
      [url: base_url <> "/onboarding/#{slug}"]
      |> Keyword.merge(req_options())

    case Req.get(req_opts) do
      {:ok, %{status: 200, body: %{"message" => %{"message" => _, "metadata" => _} = msg}}} ->
        {:ok, msg}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("User portal metadata returned #{status}: #{inspect(body)}")
        :unavailable

      {:ok, _} ->
        :unavailable

      {:error, reason} ->
        Logger.warning("User portal metadata HTTP error: #{inspect(reason)}")
        :unavailable
    end
  end

  defp req_options do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
