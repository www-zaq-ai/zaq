defmodule Zaq.TestSupport.WhatsAppOfflineTransport do
  @moduledoc "Uses Amarula's offline receive pipeline with the real sender identity lookup."

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  def connect(config, opts) do
    result =
      Amarula.Testing.start_offline(
        profile: config.profile,
        parent_pid: Keyword.fetch!(opts, :parent),
        frame_sink: config.test_pid,
        storage: {Amarula.Storage.File, root: config.storage_root}
      )

    send(config.test_pid, {:offline_connection, result})
    result
  end

  defdelegate canonical_user_id(conn, jid), to: AmarulaClient
  defdelegate account_jids(conn), to: AmarulaClient
  defdelegate resolve_conn(opts), to: AmarulaClient

  def stop(conn, _opts), do: Amarula.stop(conn)
end
