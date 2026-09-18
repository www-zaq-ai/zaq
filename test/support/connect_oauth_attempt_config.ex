defmodule Zaq.TestSupport.ConnectOAuthAttemptConfig do
  @moduledoc false
  def get(:zaq, :connect_oauth_http_client, _default), do: Zaq.TestSupport.ConnectOAuthAttemptHTTP
  def get(app, key, default), do: Application.get_env(app, key, default)
end
