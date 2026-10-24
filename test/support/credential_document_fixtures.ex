defmodule Zaq.CredentialDocumentFixtures do
  @moduledoc false

  alias Zaq.Engine.Connect

  def document(binding, op, fields \\ %{}),
    do: Connect.credential_document(Map.merge(fields, %{binding: binding, op: op}))

  def credential_document_fixture do
    config = Zaq.WhatsAppFixtures.connector(%{name: "Document #{Ecto.UUID.generate()}"})

    {:ok, binding} = Connect.credential_document(%{op: :bind, channel_config_id: config.id})
    binding
  end
end
