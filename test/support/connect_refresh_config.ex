defmodule Zaq.TestSupport.ConnectRefreshConfig do
  @moduledoc false
  def get(:zaq, :connect_oauth_http_client, _default, _opts),
    do: Zaq.TestSupport.ConnectOAuthAttemptHTTP

  def get(:zaq, Zaq.System.SecretConfig, _default, opts),
    do: Keyword.fetch!(opts, :encryption_config)

  def get(app, key, default, _opts), do: Application.get_env(app, key, default)
end
