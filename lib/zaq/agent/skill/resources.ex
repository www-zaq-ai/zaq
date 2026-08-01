defmodule Zaq.Agent.Skill.Resources do
  @moduledoc """
  Reads and edits a skill's `resources` map, and derives where its files are written.

  Two jobs, both pure:

    * **References** — `references/1`, `add_reference/3`, `remove_reference/2` return plain
      data. Persisting is `Zaq.Agent.Skills`' job.
    * **Destinations** — `destination/2` derives the volume-relative path an uploaded file
      should be written to, under `.agents/skills/{slug}/references/`, so the files show up
      in the BO ingestion browser like any other ingested file.

  It never touches the filesystem, never resolves against a volume root, and never decides
  whether a path exists. Resolution and the authoritative containment check belong to the
  `:ingestion` role — the only node guaranteed to have the volume mounted. Keeping this
  separate is what lets the BO node compute a destination for a volume it cannot itself see.

  The sanitising here is a *shape* guard, not a security boundary: it guarantees the string
  handed to ingestion is a safe relative path, so a malicious client filename cannot express
  an escape in the first place. Ingestion still rejects traversal independently.

  ## Why there is no stored root any more

  References used to be paths, so a skill carried a sticky `resource_root` — renaming it
  would otherwise have orphaned every file already uploaded under the old name. References
  are now document ids, which do not move when a name does, so the root is derived fresh
  every time and nothing can be stranded. A rename changes only where *subsequent* uploads
  land.
  """

  alias Zaq.Agent.Skill

  @root_prefix ".agents/skills"
  @references_dir "references"
  @fallback_slug "skill"
  @fallback_filename "file"

  @doc """
  The file references a skill declares, as stored.

      iex> Zaq.Agent.Skill.Resources.references(%Zaq.Agent.Skill{})
      []
  """
  @spec references(Skill.t()) :: [map()]
  def references(%Skill{resources: %{"references" => references}}) when is_list(references),
    do: references

  def references(%Skill{}), do: []

  @doc """
  Returns the skill's `resources` map with one reference added.

  Adding a `file_id` that is already referenced is a no-op, so a retried upload cannot
  double-list a file.
  """
  @spec add_reference(Skill.t(), String.t() | integer(), String.t()) :: map()
  def add_reference(%Skill{} = skill, file_id, provider) do
    file_id = to_string(file_id)
    existing = references(skill)

    if Enum.any?(existing, &(Map.get(&1, "file_id") == file_id)) do
      put_references(skill, existing)
    else
      put_references(skill, existing ++ [%{"file_id" => file_id, "provider" => provider}])
    end
  end

  @doc """
  Returns the skill's `resources` map with one reference removed.

  Removing an absent `file_id` is a no-op.
  """
  @spec remove_reference(Skill.t(), String.t() | integer()) :: map()
  def remove_reference(%Skill{} = skill, file_id) do
    file_id = to_string(file_id)

    put_references(skill, Enum.reject(references(skill), &(Map.get(&1, "file_id") == file_id)))
  end

  defp put_references(%Skill{resources: resources}, references) when is_map(resources),
    do: Map.put(resources, "references", references)

  defp put_references(%Skill{}, references), do: %{"references" => references}

  @doc """
  The resource root for a skill — everything belonging to it lives under this path.

      iex> Zaq.Agent.Skill.Resources.root(%Zaq.Agent.Skill{name: "pricing-faq"})
      ".agents/skills/pricing-faq"
  """
  @spec root(Skill.t()) :: String.t()
  def root(%Skill{name: name}), do: Path.join(@root_prefix, slug(name))

  @doc """
  The directory holding a skill's reference files.

      iex> Zaq.Agent.Skill.Resources.references_dir(%Zaq.Agent.Skill{name: "pricing-faq"})
      ".agents/skills/pricing-faq/references"
  """
  @spec references_dir(Skill.t()) :: String.t()
  def references_dir(%Skill{} = skill), do: Path.join(root(skill), @references_dir)

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

  @doc """
  Normalises a skill name into a path-safe slug.

  Jido already constrains `Skill.name` to `~r/^[a-z0-9]+(-[a-z0-9]+)*$/`, so for any
  persisted skill this is the identity. It stays as a defensive normaliser: this module
  builds filesystem paths and must not depend on a validation living in another layer.
  """
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

  # `Path.basename/1` collapses any directory component, so "a/b/c.md", "../../c.md" and
  # "/etc/c.md" all reduce to "c.md". What it cannot collapse — ".", ".." and "/" — is
  # replaced outright rather than passed through as a directory-shaped name.
  defp safe_filename(filename) when is_binary(filename) do
    case Path.basename(filename) do
      basename when basename in ["", ".", "..", "/"] -> @fallback_filename
      basename -> basename
    end
  end

  defp safe_filename(_), do: @fallback_filename
end
