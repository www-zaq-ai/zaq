defmodule Zaq.Test.StubOAuthSuccess do
  @moduledoc false

  @doc "Stub OAuth token refresh that always succeeds."
  def oauth_refresh_token(_config, _params) do
    {:ok,
     %{
       access_token: "new_access",
       refresh_token: "new_refresh",
       expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
       scopes: []
     }}
  end
end

defmodule Zaq.Test.StubNoOAuthRefresh do
  @moduledoc false

  @doc "Stub that does not implement oauth_refresh_token/2."
  def send_reply(_outgoing, _details), do: :ok
end
