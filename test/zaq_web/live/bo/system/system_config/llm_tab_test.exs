defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMTabTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [add_error: 3]
  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Zaq.System.LLMConfig
  alias ZaqWeb.Live.BO.System.SystemConfig.LLMTab

  test "model validation error renders below the model text input" do
    error = "model value rejected"
    html = render_panel(%{model: error})

    assert [form_tag] = Regex.run(~r/<form\b[^>]*>/, html)
    assert form_tag =~ ~s(phx-submit="save_llm")
    assert form_tag =~ ~s(phx-change="validate_llm")
    assert form_tag =~ ~s(id="llm-config-form")
    assert field_error(html, "model") == error
    refute field_error(html, "credential_id") =~ error
  end

  test "maximum cosine distance error is distinct from its help text" do
    error = "cosine distance exceeds maximum"
    html = render_panel(%{max_cosine_distance: error})

    assert field_error(html, "max_cosine_distance") == error
    refute field_error(html, "fusion_vector_weight") =~ error

    valid_html = render_panel(%{})
    assert field_error(valid_html, "max_cosine_distance") == ""

    assert field_help(valid_html, "max_cosine_distance") =~
             "Lower is closer; cosine similarity is 1 − distance."
  end

  test "fusion vector weight error stays in its field within the advanced section" do
    error = "vector weight exceeds maximum"
    html = render_panel(%{fusion_vector_weight: error})

    assert html =~ ~s(<details id="llm-fusion-advanced")
    assert field_error(html, "fusion_vector_weight") == error
    refute field_error(html, "fusion_bm25_weight") =~ error
  end

  test "fusion vector and BM25 errors remain attached to their respective fields" do
    vector_error = "vector weight rejected"
    bm25_error = "BM25 weight rejected"
    html = render_panel(%{fusion_vector_weight: vector_error, fusion_bm25_weight: bm25_error})

    assert field_error(html, "fusion_vector_weight") == vector_error
    assert field_error(html, "fusion_bm25_weight") == bm25_error
  end

  defp render_panel(errors) do
    changeset =
      Enum.reduce(
        errors,
        %LLMConfig{} |> LLMConfig.changeset(%{credential_id: 1, model: "test-model"}),
        fn {field, message}, changeset ->
          add_error(changeset, field, message)
        end
      )
      |> Map.put(:action, :validate)

    render_component(&LLMTab.panel/1,
      form: to_form(changeset, as: :llm_config),
      credential_options: [],
      model_options: [],
      capabilities: %{}
    )
  end

  defp field_error(html, field) do
    field_name = Regex.escape("llm_config[#{field}]")

    case Regex.run(
           ~r/<input\b[^>]*\bname="#{field_name}"[^>]*>\s*<p\b[^>]*class="([^"]*)"[^>]*>(.*?)<\/p>/s,
           html,
           capture: :all
         ) do
      [_, classes, message] ->
        if classes =~ ~r/\btext-red-500\b/, do: String.trim(message), else: ""

      _ ->
        ""
    end
  end

  defp field_help(html, field) do
    field_name = Regex.escape("llm_config[#{field}]")

    case Regex.run(
           ~r/<input\b[^>]*\bname="#{field_name}"[^>]*>\s*<p\b[^>]*class="([^"]*)"[^>]*>(.*?)<\/p>/s,
           html,
           capture: :all
         ) do
      [_, classes, message] ->
        if classes =~ ~r/\bzaq-text-caption\b/, do: String.trim(message), else: ""

      _ ->
        ""
    end
  end
end
