defmodule Zaq.Agent.PromptTemplateTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.PromptTemplate

  @valid_attrs %{
    slug: "test_prompt",
    name: "Test Prompt",
    body: "You are a helpful assistant.",
    description: "A test prompt template"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = PromptTemplate.changeset(%PromptTemplate{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without slug" do
      attrs = Map.delete(@valid_attrs, :slug)
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)
      refute changeset.valid?
    end

    test "invalid without name" do
      attrs = Map.delete(@valid_attrs, :name)
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)
      refute changeset.valid?
    end

    test "invalid without body" do
      attrs = Map.delete(@valid_attrs, :body)
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)
      refute changeset.valid?
    end

    test "defaults active to true" do
      changeset = PromptTemplate.changeset(%PromptTemplate{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :active) == true
    end
  end

  describe "create/1" do
    test "inserts a prompt template" do
      assert {:ok, template} = PromptTemplate.create(@valid_attrs)
      assert template.slug == "test_prompt"
      assert template.name == "Test Prompt"
      assert template.body == "You are a helpful assistant."
      assert template.active == true
    end

    test "enforces unique slug" do
      assert {:ok, _} = PromptTemplate.create(@valid_attrs)
      assert {:error, changeset} = PromptTemplate.create(@valid_attrs)
      assert {"has already been taken", _} = changeset.errors[:slug]
    end
  end

  describe "get_active/1" do
    test "returns body for active template" do
      {:ok, _} = PromptTemplate.create(@valid_attrs)
      assert {:ok, "You are a helpful assistant."} = PromptTemplate.get_active("test_prompt")
    end

    test "returns error for nonexistent slug" do
      assert {:error, :not_found} = PromptTemplate.get_active("nonexistent")
    end

    test "returns error for inactive template" do
      {:ok, _} = PromptTemplate.create(Map.put(@valid_attrs, :active, false))
      assert {:error, :not_found} = PromptTemplate.get_active("test_prompt")
    end
  end

  describe "get_active!/1" do
    test "returns body for active template" do
      {:ok, _} = PromptTemplate.create(@valid_attrs)
      assert "You are a helpful assistant." = PromptTemplate.get_active!("test_prompt")
    end

    test "raises for nonexistent slug" do
      assert_raise RuntimeError, ~r/not found/, fn ->
        PromptTemplate.get_active!("nonexistent")
      end
    end
  end

  describe "get_by_slug/1" do
    test "returns full record" do
      {:ok, _} = PromptTemplate.create(@valid_attrs)
      template = PromptTemplate.get_by_slug("test_prompt")
      assert template.slug == "test_prompt"
      assert template.name == "Test Prompt"
    end

    test "returns nil for nonexistent slug" do
      assert PromptTemplate.get_by_slug("nonexistent") == nil
    end
  end

  describe "list/0" do
    test "returns all templates ordered by slug" do
      {:ok, _} = PromptTemplate.create(%{@valid_attrs | slug: "b_prompt", name: "B"})
      {:ok, _} = PromptTemplate.create(%{@valid_attrs | slug: "a_prompt", name: "A"})

      templates = PromptTemplate.list()
      slugs = Enum.map(templates, & &1.slug)
      pos_a = Enum.find_index(slugs, &(&1 == "a_prompt"))
      pos_b = Enum.find_index(slugs, &(&1 == "b_prompt"))

      assert is_integer(pos_a)
      assert is_integer(pos_b)
      assert pos_a < pos_b
    end
  end

  describe "update/2" do
    test "updates template fields" do
      {:ok, template} = PromptTemplate.create(@valid_attrs)
      assert {:ok, updated} = PromptTemplate.update(template, %{body: "Updated body"})
      assert updated.body == "Updated body"
    end
  end

  describe "render/2" do
    test "interpolates EEx variables in template body" do
      {:ok, _} =
        PromptTemplate.create(%{
          @valid_attrs
          | slug: "render_test",
            body: "Answer in <%= @language %> language. Data: <%= @data %>"
        })

      result = PromptTemplate.render("render_test", %{language: "en", data: "test data"})
      assert result == "Answer in en language. Data: test data"
    end

    test "renders template without variables" do
      {:ok, _} = PromptTemplate.create(@valid_attrs)
      result = PromptTemplate.render("test_prompt")
      assert result == "You are a helpful assistant."
    end
  end
end
