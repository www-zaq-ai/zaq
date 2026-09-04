defmodule Zaq.Agent.Skill.Resources do
  @moduledoc """
  Derives the data-source paths that hold a skill's resource files.

  A skill's resources live in a flat `{slug}/` folder under the globally configured data-source
  folder, and need no separate storage mechanism.

  ## This module is pure

  It derives *path strings* and nothing else. It never touches the filesystem, never
  resolves against a volume root, and never decides whether a path exists. Resolution and
  the authoritative containment check belong to the `:storage` role — the only node
  guaranteed to have the volume mounted (see `Zaq.Storage.FileExplorer.resolve_path/2`,
  which re-checks containment against the real volume root). Keeping this separate is
  what lets the BO node compute a destination for a volume it cannot itself see.

  The sanitising here is therefore a *shape* guard, not a security boundary: it
  guarantees the string handed to ingestion is a safe relative path, so a malicious
  client filename cannot express an escape in the first place. Storage still rejects
  traversal independently.

  ## `resource_root` is sticky

  Once `Skill.resource_root` is set it wins over the name-derived default, so renaming a
  skill does not orphan files already uploaded under the old name. A stored root that is
  not a safe relative path is ignored in favour of the derived one.
  """

  alias Zaq.Agent.Skill

  @resource_types ~w(reference asset script)
  @fallback_slug "skill"
  @fallback_filename "file"
  @default_resource_type "reference"

  @doc """
  The name-derived resource root for a skill, ignoring any stored `resource_root`.

      iex> Zaq.Agent.Skill.Resources.default_root(%Zaq.Agent.Skill{name: "pricing-faq"})
      "pricing-faq"
  """
  @spec default_root(Skill.t()) :: String.t()
  def default_root(%Skill{name: name}), do: slug(name)

  @doc """
  The skill's effective resource root — everything belonging to this skill lives under it.

  Uses the stored `resource_root` when it is present and safe, else `default_root/1`. This
  is the directory to remove when a skill is deleted; `references_dir/1` is only one child
  of it.
  """
  @spec root(Skill.t()) :: String.t()
  def root(%Skill{resource_root: stored} = skill) do
    case sanitize_root(stored) do
      nil -> default_root(skill)
      root -> root
    end
  end

  @doc """
  The directory holding a skill's files.

  Kept under the old name because callers still mean "the directory to list/load resource files
  from". It now returns the flat skill root.
  """
  @spec references_dir(Skill.t()) :: String.t()
  def references_dir(%Skill{} = skill), do: root(skill)

  @doc """
  The destination path for an uploaded file, relative to the configured data-source folder.

  `filename` is client-supplied: it is reduced to a bare basename, so directory
  components and traversal segments cannot survive.

      iex> skill = %Zaq.Agent.Skill{name: "pricing-faq"}
      iex> Zaq.Agent.Skill.Resources.destination(skill, "../../etc/passwd")
      "pricing-faq/passwd"
  """
  @spec destination(Skill.t(), String.t()) :: String.t()
  def destination(%Skill{} = skill, filename) do
    Path.join(references_dir(skill), safe_filename(filename))
  end

  @doc "Returns supported Agent Skill resource classifications."
  @spec resource_types() :: [String.t()]
  def resource_types, do: @resource_types

  @doc "Normalizes a user-supplied resource classification."
  @spec normalize_resource_type(term()) :: String.t()
  def normalize_resource_type(type) when is_binary(type) do
    type = String.trim(type)

    if type in @resource_types do
      type
    else
      @default_resource_type
    end
  end

  def normalize_resource_type(_type), do: @default_resource_type

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

  # A stored root is honoured only if it is a safe relative path. The `Skill` changeset
  # already rejects absolute paths and `..`, so this is belt-and-braces for records
  # written before that validation, or by a future import path.
  defp sanitize_root(root) when is_binary(root) do
    trimmed = String.trim(root)

    cond do
      trimmed == "" -> nil
      String.starts_with?(trimmed, "/") -> nil
      ".." in Path.split(trimmed) -> nil
      true -> Path.join(Path.split(trimmed))
    end
  end

  defp sanitize_root(_), do: nil

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
