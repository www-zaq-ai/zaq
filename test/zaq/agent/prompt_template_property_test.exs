defmodule Zaq.Agent.PromptTemplatePropertyTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.PromptTemplate

  property "edits preserve independent defaults and restore releases ownership" do
    check all(
            baseline <- string(:alphanumeric, min_length: 1),
            suffix <- string(:alphanumeric, min_length: 1),
            max_runs: 25
          ) do
      slug = "property_#{System.unique_integer([:positive])}"
      {:ok, original} = PromptTemplate.create(%{slug: slug, name: "Property", body: baseline})
      {:ok, edited} = PromptTemplate.update(original, %{body: baseline <> suffix})
      assert edited.default_body == baseline
      assert edited.body_customized

      Repo.update_all(from(t in PromptTemplate, where: t.id == ^edited.id),
        set: [default_body: suffix]
      )

      assert PromptTemplate.get_active!(slug) == baseline <> suffix
      {:ok, restored} = PromptTemplate.restore_default(edited.id)
      assert restored.body == restored.default_body
      assert restored.body == suffix
      refute restored.body_customized
    end
  end
end
