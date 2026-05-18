defmodule ZaqWeb.Live.BO.Communication.OAuthClaimStateTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias ZaqWeb.Live.BO.Communication.OAuthClaimState

  defp persisted_config_changeset(settings) do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => settings
      })
      |> Repo.insert!()

    ChannelConfig.changeset(config, %{})
  end

  defp oauth_credential!(attrs) do
    base = %{
      name: "oauth-#{System.unique_integer([:positive])}",
      provider: "google_drive",
      auth_kind: "oauth2",
      request_format: "bearer",
      user_level: false,
      metadata: %{},
      client_id: "client-id",
      client_secret: "client-secret",
      scopes: ["scope.read"]
    }

    {:ok, credential} = Connect.create_credential(Map.merge(base, attrs))
    credential
  end

  test "for_changeset returns unsaved_config when config is not persisted" do
    changeset = ChannelConfig.changeset(%ChannelConfig{}, %{"settings" => %{}})

    assert OAuthClaimState.for_changeset(changeset) == %{
             enabled?: false,
             url: nil,
             message: "Save this Data Source first to claim a grant."
           }
  end

  test "for_changeset returns missing_credential when credential is not selected" do
    changeset = persisted_config_changeset(%{})

    assert OAuthClaimState.for_changeset(changeset) == %{
             enabled?: false,
             url: nil,
             message: "Select an OAuth2 credential to claim a grant."
           }
  end

  test "for_changeset returns credential_not_found when selected credential does not exist" do
    changeset =
      persisted_config_changeset(%{"connect" => %{"credential_id" => "99999999"}})

    assert OAuthClaimState.for_changeset(changeset) == %{
             enabled?: false,
             url: nil,
             message: "Selected credential was not found."
           }
  end

  test "for_changeset returns non_oauth_credential for api_key credentials" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "api-key-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "secret"
      })

    changeset =
      persisted_config_changeset(%{
        "connect" => %{"credential_id" => Integer.to_string(credential.id)}
      })

    assert OAuthClaimState.for_changeset(changeset) == %{
             enabled?: false,
             url: nil,
             message: "Selected credential uses api_key; no OAuth2 claim needed."
           }
  end

  test "for_changeset returns build_authorize_url_failed when oauth url cannot be built" do
    credential = oauth_credential!(%{provider: "provider_without_oauth_adapter"})

    changeset =
      persisted_config_changeset(%{
        "connect" => %{"credential_id" => Integer.to_string(credential.id)}
      })

    assert OAuthClaimState.for_changeset(changeset) == %{
             enabled?: false,
             url: nil,
             message: "Could not build OAuth claim URL for this credential."
           }
  end

  test "for_changeset fallback for non changeset inputs" do
    assert OAuthClaimState.for_changeset(nil) == %{
             enabled?: false,
             url: nil,
             message: "Select an OAuth2 credential to claim a grant."
           }
  end
end
