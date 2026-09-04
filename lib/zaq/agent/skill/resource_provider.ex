defmodule Zaq.Agent.Skill.ResourceProvider do
  @moduledoc """
  ZAQ host adapter for Jido's runtime Agent Skills resource provider.

  The adapter maps Jido's generic list/load callbacks onto ZAQ's existing
  data-source document actions through `Jido.Exec`. It never calls channel bridges
  directly and never accepts caller-supplied provider identity from the model.
  """

  alias Jido.AI.Skill.Spec
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resource
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Contracts.Record

  @doc false
  def handle(%{operation: :list, skill: %Spec{name: name}}, _context) do
    with {:ok, skill} <- fetch_skill(name) do
      resources =
        skill
        |> Skills.list_skill_resources()
        |> Enum.map(&resource_entry/1)

      {:ok, %{resources: resources, complete: true}}
    end
  end

  def handle(%{operation: :load, skill: %Spec{name: name}, resource_id: resource_id}, context)
      when is_binary(resource_id) do
    with {:ok, skill} <- fetch_skill(name),
         {:ok, location} <- Skills.resource_location(skill),
         %Resource{} = resource <- Skills.get_skill_resource_by_provider_id(skill, resource_id),
         {:ok, %Record{materialization_handle: handle} = record} <-
           get_document(location, resource, context),
         {:ok, %{record: %Record{content: content} = loaded_record}} <-
           Jido.Exec.run(DownloadDocument, download_params(handle, record), context),
         {:ok, text} <- text_content(content) do
      {:ok,
       %{
         resource_id: resource.provider_resource_id,
         content: text,
         mime_type: loaded_record.mime_type || record.mime_type || resource.mime_type,
         size: byte_size(text)
       }}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def handle(_request, _context), do: {:error, :unsupported_skill_resource_request}

  defp fetch_skill(name) do
    case Skills.search_skills(%{q: name, active: true}) do
      [%Skill{name: ^name} = skill | _] -> {:ok, skill}
      _ -> {:error, :skill_not_found}
    end
  end

  defp get_params(location, %Resource{} = resource) do
    %{
      provider: location.provider,
      config_id: to_string(location.config_id),
      document_id: resource.provider_resource_id
    }
  end

  defp get_document(location, %Resource{} = resource, context) do
    case Jido.Exec.run(GetDocument, get_params(location, resource), context) do
      {:ok, %{record: %Record{materialization_handle: handle} = record}} when is_binary(handle) ->
        {:ok, record}

      {:ok, %{record: %Record{}}} ->
        {:error, :materialization_handle_missing}

      other ->
        other
    end
  end

  defp download_params(handle, %Record{} = record) do
    %{
      materialization_handle: handle,
      document_mime_type: record.mime_type
    }
  end

  defp resource_entry(%Resource{} = resource) do
    %{
      id: resource.provider_resource_id,
      name: resource.name,
      type: resource.resource_type,
      size: resource.size || 0,
      modified: resource.modified_at,
      mime_type: resource.mime_type
    }
  end

  defp text_content(content) when is_binary(content), do: {:ok, content}
  defp text_content(_content), do: {:error, :binary_resource}
end
