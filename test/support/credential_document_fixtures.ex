defmodule Zaq.CredentialDocumentFixtures do
  @moduledoc false

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Repo

  def credential_document_fixture do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Document #{Ecto.UUID.generate()}",
        provider: "whatsapp",
        kind: "retrieval"
      })
      |> Repo.insert!()

    {:ok, saved} =
      Connect.save_credential_configuration(
        nil,
        %{
          name: "document-#{Ecto.UUID.generate()}",
          provider: config.provider,
          auth_kind: "api_key",
          secret_binding: :grant,
          personal_credential_policy: :disabled,
          metadata: %{
            "auth_profile_id" => "credential_document_v1",
            "subject" => "channel_config:#{config.id}"
          }
        },
        {:replace, %{api_key: ~s({"version":1,"records":{}})}}
      )

    config
    |> Ecto.Changeset.change(settings: %{"credential_document_id" => saved.credential_id})
    |> Repo.update!()

    %{channel_config_id: config.id, credential_id: saved.credential_id}
  end
end
