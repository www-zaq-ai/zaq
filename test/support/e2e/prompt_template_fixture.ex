defmodule Zaq.E2E.PromptTemplateFixture do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Agent.PromptTemplate
  alias Zaq.Repo

  @slugs ["e2e_default_following", "e2e_default_customized", "e2e_default_legacy"]

  def seed! do
    Repo.delete_all(from(t in PromptTemplate, where: t.slug in @slugs))

    for {slug, body, default, customized} <- [
          {"e2e_default_following", "Release default v1", "Release default v1", false},
          {"e2e_default_customized", "User-owned body", "Release default v1", true},
          {"e2e_default_legacy", "Legacy custom body", nil, true}
        ],
        into: %{} do
      template =
        Repo.insert!(%PromptTemplate{
          slug: slug,
          name: slug,
          body: body,
          default_body: default,
          body_customized: customized
        })

      {slug, template.id}
    end
  end

  # Deterministic release-state fixture, not a browser-triggered migration.
  # Actual upgrade classification is covered by private-schema migration replay.
  def publish!(body) do
    Repo.update_all(
      from(t in PromptTemplate,
        where: t.slug in ^Enum.take(@slugs, 2),
        update: [
          set: [
            default_body: ^body,
            body: fragment("CASE WHEN body_customized THEN body ELSE ? END", ^body)
          ]
        ]
      ),
      []
    )

    :ok
  end
end
