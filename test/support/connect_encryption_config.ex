defmodule Zaq.TestSupport.ConnectEncryptionConfig do
  @moduledoc false

  def get(:zaq, Zaq.System.SecretConfig, _default, opts),
    do: Keyword.fetch!(opts, :encryption_config)
end
