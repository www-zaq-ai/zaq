defmodule Zaq.TestSupport.DeviceBrowserHTTP do
  @moduledoc "Stateful provider HTTP fixture for sandboxed device browser journeys only."
  use Agent

  def start_link(_),
    do: Agent.start_link(fn -> %{next: 0, approved: MapSet.new()} end, name: __MODULE__)

  def approve(id), do: Agent.update(__MODULE__, &%{&1 | approved: MapSet.put(&1.approved, id)})

  def post(opts) do
    case URI.parse(opts[:url]).path do
      "/api/accounts/deviceauth/usercode" -> initiate(opts)
      "/api/accounts/deviceauth/token" -> poll(opts)
      "/oauth/token" -> exchange(opts)
    end
  end

  defp initiate(opts) do
    false = opts[:retry]
    false = opts[:redirect]
    %{} = opts[:json]

    id =
      Agent.get_and_update(__MODULE__, fn state ->
        id = state.next + 1
        {"device-#{id}", %{state | next: id}}
      end)

    {:ok,
     %{
       status: 200,
       body: %{"device_auth_id" => id, "user_code" => "BROWSER-CODE", "interval" => 1}
     }}
  end

  defp poll(opts) do
    id = opts[:json]["device_auth_id"]

    if Agent.get(__MODULE__, &MapSet.member?(&1.approved, id)) do
      {:ok,
       %{status: 200, body: %{"authorization_code" => id, "code_verifier" => "BROWSER-VERIFIER"}}}
    else
      {:ok, %{status: 403, body: %{}}}
    end
  end

  defp exchange(opts) do
    "https://auth.openai.com/deviceauth/callback" = opts[:form]["redirect_uri"]
    "BROWSER-VERIFIER" = opts[:form]["code_verifier"]

    {:ok,
     %{
       status: 200,
       body: %{
         "access_token" => "BROWSER-ACCESS-SECRET",
         "refresh_token" => "BROWSER-REFRESH-SECRET",
         "expires_in" => 3600
       }
     }}
  end
end
