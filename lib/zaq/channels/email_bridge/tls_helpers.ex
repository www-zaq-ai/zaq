defmodule Zaq.Channels.EmailBridge.TlsHelpers do
  @moduledoc """
  Shared TLS helpers for email bridge SMTP and IMAP transports.
  """

  def default_cacerts do
    :public_key.cacerts_get()
    |> Enum.flat_map(fn
      {:cert, der, _} when is_binary(der) -> [der]
      der when is_binary(der) -> [der]
      _ -> []
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
