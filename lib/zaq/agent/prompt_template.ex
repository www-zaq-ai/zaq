defmodule Zaq.Agent.PromptTemplate do
  @moduledoc """
  Schema and context for DB-stored system prompts.

  Prompt templates are editable via the Back Office and fetched by slug
  at runtime by agent modules (Retrieval, Answering, ChunkTitle).

  ## Slugs

    * `"retrieval"` — query rewriting / retrieval agent
    * `"answering"` — response formulation agent
    * `"chunk_title"` — chunk title generation during ingestion
    * `"image_to_text"` — vision model prompt for image description during PDF ingestion

  ## Placeholders

  The `body` field supports EEx-style placeholders that agents interpolate
  at call time. For example:

      Write your answer in <%= language %> ISO 639-3 language

  Agents call `render/2` to interpolate:

      PromptTemplate.render("answering", %{language: "en"})
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Repo

  schema "prompt_templates" do
    field :slug, :string
    field :name, :string
    field :body, :string
    field :description, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(slug name body)a
  @optional_fields ~w(description active)a

  def changeset(template, attrs) do
    template
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:slug)
  end

  # -- Query API --

  @doc """
  Returns the active prompt template body for the given slug.
  Raises if not found.

  ## Example

      body = PromptTemplate.get_active!("retrieval")
  """
  def get_active!(slug) do
    case get_active(slug) do
      {:ok, body} -> body
      {:error, :not_found} -> raise "PromptTemplate not found for slug: #{slug}"
    end
  end

  @doc """
  Returns the active prompt template body for the given slug.

  ## Example

      {:ok, body} = PromptTemplate.get_active("retrieval")
      {:error, :not_found} = PromptTemplate.get_active("nonexistent")
  """
  def get_active(slug) do
    query =
      from pt in __MODULE__,
        where: pt.slug == ^slug and pt.active == true,
        select: pt.body

    case Repo.one(query) do
      nil -> {:error, :not_found}
      body -> {:ok, body}
    end
  end

  @doc """
  Returns the full prompt template record for the given slug.
  """
  def get_by_slug(slug) do
    Repo.get_by(__MODULE__, slug: slug)
  end

  @doc """
  Lists all prompt templates.
  """
  def list do
    from(pt in __MODULE__, order_by: [asc: pt.slug])
    |> Repo.all()
  end

  @doc """
  Creates a new prompt template.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing prompt template.
  """
  def update(%__MODULE__{} = template, attrs) do
    template
    |> changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Renders a prompt template body with the given variables.

  Fetches the active template by slug, then interpolates EEx placeholders.

  ## Example

      PromptTemplate.render("answering", %{language: "en", retrieved_data: "..."})
  """
  def render(slug, assigns \\ %{}) do
    body = get_active!(slug)
    EEx.eval_string(body, assigns: assigns)
  end
end
