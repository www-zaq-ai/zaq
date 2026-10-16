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

  describe "default ownership" do
    test "creation snapshots the validated body and ignores protected parameters" do
      attrs = Map.merge(@valid_attrs, %{default_body: "forged", body_customized: true})
      assert {:ok, template} = PromptTemplate.create(attrs)
      assert template.default_body == template.body
      refute template.body_customized
    end

    test "body edits customize; unchanged and metadata saves preserve ownership" do
      {:ok, original} = PromptTemplate.create(@valid_attrs)
      {:ok, metadata} = PromptTemplate.update(original, %{name: "Renamed", active: false})
      refute metadata.body_customized

      {:ok, edited} = PromptTemplate.update(metadata, %{body: "User content"})
      assert edited.body_customized
      assert edited.default_body == original.body

      {:ok, unchanged} =
        PromptTemplate.update(edited, %{
          body: edited.body,
          default_body: "forged",
          body_customized: false
        })

      assert unchanged.body_customized
      assert unchanged.default_body == original.body

      {:ok, typed_default} = PromptTemplate.update(unchanged, %{body: original.body})
      assert typed_default.body_customized
    end

    test "updates classify changes against current storage rather than a stale struct" do
      {:ok, stale} = PromptTemplate.create(@valid_attrs)
      {:ok, _} = PromptTemplate.update(stale, %{body: "Changed elsewhere"})
      {:ok, updated} = PromptTemplate.update(stale, %{body: stale.body})
      assert updated.body_customized
      assert updated.body == stale.body
    end

    test "restore uses the latest default and preserves metadata and inactive state" do
      {:ok, original} = PromptTemplate.create(Map.put(@valid_attrs, :active, false))
      {:ok, _} = PromptTemplate.update(original, %{body: "Custom", description: "Keep"})

      Repo.update_all(from(t in PromptTemplate, where: t.id == ^original.id),
        set: [default_body: "New shipped default"]
      )

      assert {:ok, restored} = PromptTemplate.restore_default(original.id)
      assert restored.body == "New shipped default"
      refute restored.body_customized
      refute restored.active
      assert restored.description == "Keep"
      assert {:ok, again} = PromptTemplate.restore_default(original.id)
      assert again.body == restored.body
    end

    test "restore errors do not destroy the current body" do
      {:ok, template} = PromptTemplate.create(@valid_attrs)

      Repo.update_all(from(t in PromptTemplate, where: t.id == ^template.id),
        set: [default_body: nil]
      )

      assert {:error, :no_default} = PromptTemplate.restore_default(template.id)
      assert PromptTemplate.get_by_slug(template.slug).body == template.body
      Repo.delete!(template)
      assert {:error, :not_found} = PromptTemplate.restore_default(template.id)
      assert {:error, :not_found} = PromptTemplate.update(template, %{body: "Gone"})
    end

    test "invalid edits leave ownership and storage unchanged" do
      {:ok, template} = PromptTemplate.create(@valid_attrs)
      assert {:error, %Ecto.Changeset{}} = PromptTemplate.update(template, %{body: ""})
      stored = PromptTemplate.get_by_slug(template.slug)
      assert stored.body == template.body
      refute stored.body_customized
    end

    test "runtime lookup and rendering use the customized body, not the default" do
      {:ok, template} = PromptTemplate.create(@valid_attrs)
      {:ok, _} = PromptTemplate.update(template, %{body: "Visible <%= @value %>"})
      assert {:ok, "Visible <%= @value %>"} = PromptTemplate.get_active(template.slug)
      assert PromptTemplate.render(template.slug, %{value: "text"}) == "Visible text"
    end
  end
end
