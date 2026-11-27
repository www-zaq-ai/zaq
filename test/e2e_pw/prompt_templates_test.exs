defmodule Zaq.E2EPw.PromptTemplatesTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Prompt template defaults
  setup %{page: page, request: request} do
    # Not in the spec, which relied on an earlier file's reset (the files ran in a fixed order):
    # tests run in random order, and onboarding's bootstrap admin deletes e2e_admin.
    reset_e2e_state(request)
    templates = seed_e2e_prompt_template_defaults(request)
    login_to_back_office(page, return_to: "/bo/prompt-templates")
    %{templates: templates}
  end

  defp name_input(page), do: Page.locator(page, ~s|input[name="prompt_template[name]"]|)

  test "edited bodies persist across upgrades; restore uses latest default and opts back in", %{
    page: page,
    request: request,
    templates: templates
  } do
    slug = "e2e_default_following"
    id = templates[slug]
    body = open_prompt_template(page, slug)
    Expect.to_have_value!(body, "Release default v1")
    Locator.fill!(body, "My edited image extraction instructions")
    page |> Page.locator("#save-template-#{id}") |> Locator.click!()
    wait_for_live_view_settled(page)

    publish_e2e_prompt_template_defaults(request, "Release default v2")
    body = open_prompt_template(page, slug)
    Expect.to_have_value!(body, "My edited image extraction instructions")

    name_input(page) |> Locator.fill!("Unsaved metadata")
    Locator.fill!(body, "Unsaved body that should be discarded")
    wait_for_live_view_settled(page)
    page |> Page.locator("#restore-template-#{id}") |> Locator.click!()
    wait_for_live_view_settled(page)
    Expect.to_have_value!(body, "Release default v2")
    Expect.to_have_value!(name_input(page), "Unsaved metadata")

    body = open_prompt_template(page, slug)
    Expect.to_have_value!(body, "Release default v2")
    Expect.to_have_value!(name_input(page), slug)

    publish_e2e_prompt_template_defaults(request, "Release default v3")
    body = open_prompt_template(page, slug)
    Expect.to_have_value!(body, "Release default v3")
  end

  test "metadata edits preserve automatic updates while existing customization is retained", %{
    page: page,
    request: request,
    templates: templates
  } do
    slug = "e2e_default_following"
    open_prompt_template(page, slug)
    Locator.fill!(name_input(page), "Renamed only")
    page |> Page.locator("#save-template-#{templates[slug]}") |> Locator.click!()
    wait_for_live_view_settled(page)
    publish_e2e_prompt_template_defaults(request, "Release default v2")

    following = open_prompt_template(page, slug)
    Expect.to_have_value!(following, "Release default v2")
    Expect.to_have_value!(name_input(page), "Renamed only")

    customized = open_prompt_template(page, "e2e_default_customized")
    Expect.to_have_value!(customized, "User-owned body")

    page
    |> Page.locator("#restore-template-#{templates["e2e_default_customized"]}")
    |> Locator.click!()

    wait_for_live_view_settled(page)
    Expect.to_have_value!(customized, "Release default v2")
  end

  test "legacy custom templates without a baseline cannot restore", %{
    page: page,
    templates: templates
  } do
    body = open_prompt_template(page, "e2e_default_legacy")
    Expect.to_have_value!(body, "Legacy custom body")

    page
    |> Page.locator("#restore-template-#{templates["e2e_default_legacy"]}")
    |> Expect.to_be_disabled!()

    page
    |> Page.get_by_text("No original default is available for this template.")
    |> Expect.to_be_visible!()
  end
end
