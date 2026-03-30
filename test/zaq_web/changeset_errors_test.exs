defmodule ZaqWeb.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.ChangesetErrors

  defmodule SampleSchema do
    use Ecto.Schema

    embedded_schema do
      field :name, :string
      field :count, :integer
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> Ecto.Changeset.cast(attrs, [:name, :count])
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.validate_number(:count, greater_than: 3)
    end
  end

  test "formats errors as a joined string by default" do
    changeset = SampleSchema.changeset(%{"name" => "", "count" => 1})

    formatted = ChangesetErrors.format(changeset)

    assert formatted =~ "name: can't be blank"
    assert formatted =~ "count: must be greater than 3"
  end

  test "supports list output with humanized fields" do
    changeset = SampleSchema.changeset(%{"name" => "", "count" => 1})

    formatted =
      ChangesetErrors.format(changeset,
        join: false,
        humanize_fields: true,
        field_separator: " "
      )

    assert "Name can't be blank" in formatted
    assert "Count must be greater than 3" in formatted
  end
end
