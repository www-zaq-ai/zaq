defmodule Zaq.UserPortal.Client do
  @moduledoc """
  HTTP client for the Zaq User Portal API.

  Handles user provisioning via POST /onboarding, which creates the user
  in LiteLLM and returns their API key.

  ## Testing

  Application code calls the portal through the configurable client returned by
  `Application.get_env(:zaq, :user_portal_client, __MODULE__)`, so tests mock
  `Zaq.UserPortal.ClientMock` (a `Mox` mock of `Zaq.UserPortal.ClientBehaviour`).

  This module — the real HTTP client — is exercised directly only by its own unit
  test, which configures `Req.Test` plumbing in its setup.
  """

  @behaviour Zaq.UserPortal.ClientBehaviour

  alias Zaq.System.MachineSignals

  require Logger

  @doc """
  Fetches onboarding metadata for the given slug.

  Returns `{:ok, metadata}` on success. Any failure — connection refused,
  timeout, non-200, or unexpected body — returns `:unavailable`.
  """
  @impl Zaq.UserPortal.ClientBehaviour
  def fetch_onboarding(slug), do: fetch_onboarding_metadata(slug)

  @impl Zaq.UserPortal.ClientBehaviour
  def onboard_user(email) when is_binary(email) do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)

    req_opts =
      [
        url: base_url <> "/onboarding",
        json: %{
          email: email,
          machine_signals: MachineSignals.collect(),
          plan: "free",
          network: build_network_payload()
        },
        retry: false
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

  @impl Zaq.UserPortal.ClientBehaviour
  def update_email(_email, nil), do: {:error, :portal_sync_failed}

  def update_email(email, api_key) when is_binary(email) and is_binary(api_key) do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)

    req_opts =
      [
        url: base_url <> "/account/email",
        json: %{email: email},
        headers: [{"authorization", "Bearer #{api_key}"}],
        retry: false
      ]
      |> Keyword.merge(req_options())

    case Req.patch(req_opts) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("User portal update_email returned #{status}: #{inspect(body)}")
        {:error, portal_error_code(status, body)}

      {:error, reason} ->
        Logger.warning("User portal update_email HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp portal_error_code(400, %{"error" => "invalid_email"}), do: :invalid_email
  defp portal_error_code(400, _), do: :invalid_payload
  defp portal_error_code(401, _), do: :unauthorized
  defp portal_error_code(403, _), do: :account_suspended
  defp portal_error_code(409, _), do: :email_taken
  defp portal_error_code(422, _), do: :same_email
  defp portal_error_code(status, body), do: {status, body}

  defp fetch_onboarding_metadata(slug) do
    base_url = Application.fetch_env!(:zaq, :user_portal_base_url)

    req_opts =
      [url: base_url <> "/onboarding/#{slug}", retry: false]
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

  # Both requests pass `retry: false` so a single logical call makes exactly one
  # HTTP request — when the portal is unreachable we surface that immediately
  # rather than letting Req's default `:safe_transient` retry the GET several times.
  # Configured `req_options` are merged last and may override this if ever needed.
  defp req_options do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp build_network_payload do
    %{
      user_agent: build_user_agent(),
      accept_lang: system_locale(),
      timezone_offset_minutes: timezone_offset_minutes()
    }
  end

  defp build_user_agent do
    version = Application.spec(:zaq, :vsn) |> to_string()
    {_type, os} = :os.type()
    "ZaqApp/#{version} (#{os})"
  end

  defp system_locale do
    case System.get_env("LANG") || System.get_env("LC_ALL") || System.get_env("LC_MESSAGES") do
      nil -> nil
      lang -> lang |> String.split(".") |> List.first() |> String.replace("_", "-")
    end
  end

  defp timezone_offset_minutes do
    :calendar.local_time()
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("local")
    |> Map.get(:utc_offset)
    |> div(60)
  rescue
    _ -> nil
  end
end
