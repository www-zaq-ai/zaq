defmodule Zaq.TestSupport.ConnectOAuthAttemptHTTP do
  @moduledoc false
  def post(opts), do: Req.post(Keyword.merge(opts, plug: {Req.Test, __MODULE__}))
end
