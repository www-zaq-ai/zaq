defmodule ZaqWeb.Live.BO.Communication.OAuthClaimState do
  @moduledoc false

  alias Zaq.Event
  alias Zaq.NodeRouter

  @spec for_changeset(Ecto.Changeset.t() | term()) :: %{
          enabled?: boolean(),
          url: String.t() | nil,
          message: String.t() | nil
        }
  def for_changeset(%Ecto.Changeset{} = changeset) do
    with {:ok, config_id} <- loaded_config_id(changeset),
         {:ok, credential_id} <- selected_credential_id(changeset),
         {:ok, credential} <- fetch_oauth_credential(credential_id),
         {:ok, url} <- build_claim_url(credential, config_id) do
      %{enabled?: true, url: url, message: nil}
    else
      {:error, :unsaved_config} ->
        %{enabled?: false, url: nil, message: "Save this Data Source first to claim a grant."}

      {:error, :missing_credential} ->
        %{enabled?: false, url: nil, message: "Select an OAuth2 credential to claim a grant."}

      {:error, :non_oauth_credential} ->
        %{
          enabled?: false,
          url: nil,
          message: "Selected credential uses api_key; no OAuth2 claim needed."
        }

      {:error, :credential_not_found} ->
        %{enabled?: false, url: nil, message: "Selected credential was not found."}

      {:error, :build_authorize_url_failed} ->
        %{
          enabled?: false,
          url: nil,
          message: "Could not build OAuth claim URL for this credential."
        }
    end
  end

  def for_changeset(_),
    do: %{enabled?: false, url: nil, message: "Select an OAuth2 credential to claim a grant."}

  defp loaded_config_id(%Ecto.Changeset{} = changeset) do
    data = changeset.data

    if data.__meta__.state == :loaded and is_integer(data.id) do
      {:ok, data.id}
    else
      {:error, :unsaved_config}
    end
  end

  defp selected_credential_id(%Ecto.Changeset{} = changeset) do
    credential_id =
      changeset
      |> Ecto.Changeset.get_field(:settings, %{})
      |> Map.get("connect", %{})
      |> Map.get("credential_id", "")

    case credential_id do
      id when id in [nil, ""] -> {:error, :missing_credential}
      id -> {:ok, id}
    end
  end

  defp fetch_oauth_credential(credential_id) do
    case dispatch_engine(:connect_fetch_credential, %{credential_id: credential_id}) do
      {:ok, credential} when credential.auth_kind == "oauth2" -> {:ok, credential}
      {:ok, _credential} -> {:error, :non_oauth_credential}
      {:error, :not_found} -> {:error, :credential_not_found}
    end
  end

  defp build_claim_url(credential, config_id) do
    case dispatch_engine(:connect_oauth_build_authorize_url, %{
           credential: credential,
           context: %{
             resource_type: "data_source",
             resource_id: config_id,
             owner_type: "org",
             owner_id: nil,
             metadata: %{source: "bo_data_sources"}
           }
         }) do
      {:ok, url} -> {:ok, url}
      _ -> {:error, :build_authorize_url_failed}
    end
  end

  defp dispatch_engine(action, request) do
    Event.new(request, :engine, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end
end
