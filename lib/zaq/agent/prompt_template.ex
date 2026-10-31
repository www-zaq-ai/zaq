defmodule Zaq.Agent.PromptTemplate do
  @moduledoc """
  Schema and context for DB-stored system prompts.

  Prompt templates are editable via the Back Office and fetched by slug
  at runtime by image ingestion.

  `body` is always the used prompt. `default_body` is the independent baseline;
  ordinary edits cannot change it. Body edits set `body_customized`; only an
  explicit restore clears it and opts back into future shipped-default updates.
  New custom templates snapshot their initial body as their baseline. Legacy
  custom templates may have no recoverable default.

  ## Slugs

    * `"image_to_text"` — vision model prompt for image description during PDF ingestion

  ## Placeholders

  The `body` field supports EEx-style placeholders that agents interpolate
  at call time. For example:

      Write your answer in <%= language %> ISO 639-3 language

  Agents call `render/2` to interpolate:

      PromptTemplate.render("image_to_text", %{language: "eng"})
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Repo

  schema "prompt_templates" do
    field :slug, :string
    field :name, :string
    field :body, :string
    field :default_body, :string
    field :body_customized, :boolean, default: true
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

      body = PromptTemplate.get_active!("image_to_text")
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

      {:ok, body} = PromptTemplate.get_active("image_to_text")
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
    changeset = changeset(%__MODULE__{}, attrs)

    changeset
    |> put_change(:default_body, get_field(changeset, :body))
    |> put_change(:body_customized, false)
    |> Repo.insert()
  end

  @doc """
  Updates an existing prompt template against its current persisted body.

  Body changes claim customization; metadata-only saves preserve ownership.
  Returns `{:error, :not_found}` when the record has been deleted.
  """
  def update(%__MODULE__{} = template, attrs) do
    with_locked_template(template.id, fn current ->
      changeset = changeset(current, attrs)

      changeset =
        if changed?(changeset, :body),
          do: put_change(changeset, :body_customized, true),
          else: changeset

      Repo.update(changeset)
    end)
  end

  @doc """
  Restores the latest persisted default and opts back into default updates.

  Changes only the body, customization flag, and update timestamp. Returns
  `{:error, :not_found}` or `{:error, :no_default}` without changing storage.
  """
  def restore_default(id) do
    with_locked_template(id, fn
      %{default_body: nil} ->
        {:error, :no_default}

      template ->
        template
        |> changeset(%{body: template.default_body})
        |> put_change(:body_customized, false)
        |> Repo.update()
    end)
  end

  @doc "Deletes a prompt template through its owning context."
  def delete(%__MODULE__{} = template), do: Repo.delete(template)

  defp with_locked_template(id, operation) do
    Repo.transaction(fn ->
      case Repo.one(from(t in __MODULE__, where: t.id == ^id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        template ->
          template |> operation.() |> transaction_result()
      end
    end)
  end

  defp transaction_result({:ok, updated}), do: updated
  defp transaction_result({:error, reason}), do: Repo.rollback(reason)

  @doc """
  Renders a prompt template body with the given variables.

  Fetches the active template by slug, then interpolates EEx placeholders.

  ## Example

      PromptTemplate.render("image_to_text", %{language: "eng"})
  """
  def render(slug, assigns \\ %{}) do
    body = get_active!(slug)
    EEx.eval_string(body, assigns: assigns)
  end
end
