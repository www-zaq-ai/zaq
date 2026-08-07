defmodule Zaq.Agent.Skill.Resources do
  @moduledoc """
  Owns a skill's `resources` map and the volume paths its files are uploaded to.

  `Skill.resources` buckets the documents a skill bundles:

      %{"references" => [%{"file_id" => "42", "file_name" => "prices.md", "provider" => "disk"}]}

  `file_id` is a `documents.id`, so reads and deletes go through the data-source bridge for
  `provider` rather than through a path. Files are uploaded under
  `.agents/skills/{slug}/references/` so they appear in the ingestion browser like any other
  ingested file.

  Path derivation here never touches the filesystem. Ingestion resolves the path against the
  volume and rejects traversal independently; the sanitising here is a shape guard so a
  malicious client filename cannot express an escape in the first place.
  """

  alias Zaq.Agent.Skill
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage

  @root_prefix ".agents/skills"
  @references "references"
  @fallback_slug "skill"
  @fallback_filename "file"

  @buckets ~w(references scripts assets)
  @entry_keys ~w(file_id file_name provider)

  @doc "The bucket names `Skill.resources` may hold."
  @spec buckets() :: [String.t()]
  def buckets, do: @buckets

  @doc "The keys every resource entry must carry."
  @spec entry_keys() :: [String.t()]
  def entry_keys, do: @entry_keys

  @doc "The skill's reference entries, or `[]` when it has none."
  @spec references(Skill.t()) :: [map()]
  def references(%Skill{resources: resources}) when is_map(resources) do
    case Map.get(resources, @references) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  def references(%Skill{}), do: []

  @doc "Appends entries to the skill's references bucket. Appending none changes nothing."
  @spec add_references(Skill.t(), [map()]) :: map()
  def add_references(%Skill{resources: resources}, []), do: resources || %{}

  def add_references(%Skill{} = skill, entries) when is_list(entries) do
    put_references(skill, references(skill) ++ entries)
  end

  @doc "Drops the reference entry naming `file_id`."
  @spec remove_reference(Skill.t(), String.t()) :: map()
  def remove_reference(%Skill{} = skill, file_id) do
    put_references(skill, Enum.reject(references(skill), &(&1["file_id"] == file_id)))
  end

  @doc "Builds a reference entry from a record written by a data-source bridge."
  @spec entry(String.t(), String.t(), String.t()) :: map()
  def entry(file_id, file_name, provider) do
    %{"file_id" => to_string(file_id), "file_name" => file_name, "provider" => provider}
  end

  @doc """
  The skill's references as unmaterialized records, for `load_skill` to hand the model.

  Records carry metadata only. A caller that wants the bytes calls the `download_document`
  tool with the record's `id` and `attributes["provider"]`.
  """
  @spec record_page(Skill.t()) :: RecordPage.t()
  def record_page(%Skill{} = skill) do
    records = skill |> references() |> Enum.map(&to_record/1)

    %RecordPage{
      resource_type: :item,
      records: records,
      stats: %{scanned: length(records), returned: length(records)}
    }
  end

  defp to_record(%{"file_id" => id, "file_name" => name, "provider" => provider}) do
    %Record{
      id: id,
      kind: :file,
      name: name,
      mime_type: MIME.from_path(name),
      attributes: %{"provider" => provider}
    }
  end

  defp put_references(%Skill{resources: resources}, entries) do
    Map.put(resources || %{}, @references, entries)
  end

  @doc """
  The directory a skill's reference files are uploaded to, relative to an ingestion volume.

      iex> Zaq.Agent.Skill.Resources.references_dir(%Zaq.Agent.Skill{name: "pricing-faq"})
      ".agents/skills/pricing-faq/references"
  """
  @spec references_dir(Skill.t()) :: String.t()
  def references_dir(%Skill{name: name}),
    do: Path.join([@root_prefix, slug(name), @references])

  @doc """
  The destination path for an uploaded file, relative to an ingestion volume.

  `filename` is client-supplied: it is reduced to a bare basename, so directory
  components and traversal segments cannot survive.

      iex> skill = %Zaq.Agent.Skill{name: "pricing-faq"}
      iex> Zaq.Agent.Skill.Resources.destination(skill, "../../etc/passwd")
      ".agents/skills/pricing-faq/references/passwd"
  """
  @spec destination(Skill.t(), String.t()) :: String.t()
  def destination(%Skill{} = skill, filename) do
    Path.join(references_dir(skill), safe_filename(filename))
  end

  @doc "Normalises a skill name into a path-safe slug."
  @spec slug(String.t() | nil) :: String.t()
  def slug(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> @fallback_slug
      slug -> slug
    end
  end

  def slug(_), do: @fallback_slug

  # `Path.basename/1` collapses directory components; what it cannot collapse is replaced.
  defp safe_filename(filename) when is_binary(filename) do
    case Path.basename(filename) do
      basename when basename in ["", ".", "..", "/"] -> @fallback_filename
      basename -> basename
    end
  end

  defp safe_filename(_), do: @fallback_filename
end
