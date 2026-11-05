defmodule ZaqWeb.Components.DesignSystem.AIModelSelectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.AIModelSelector

  test "catalog model and modalities share a row in both layouts" do
    for layout <- [:inline, :stacked] do
      html = render_selector(layout: layout)
      document = LazyHTML.from_fragment(html)

      assert html =~ "zaq-ai-model-selector--#{layout}"
      assert Enum.any?(LazyHTML.query(document, ".zaq-ai-model-row #example-model-select"))
      assert Enum.any?(LazyHTML.query(document, ".zaq-ai-model-row #example-modalities"))
      assert html =~ "Input: Text"
      assert html =~ "Output: Text"
      refute html =~ "Enter the model ID"
    end
  end

  test "custom catalog renders manual input and unknown modalities" do
    html = render_selector(options: [], model_catalogs: %{"12" => []})
    document = LazyHTML.from_fragment(html)

    assert Enum.any?(LazyHTML.query(document, "input[name='example[model]'][type='text']"))
    assert Enum.empty?(LazyHTML.query(document, "#example-model-select"))
    assert html =~ "Input: Unknown"
    assert html =~ "Output: Unknown"
  end

  test "filtered-out catalog does not enable manual entry" do
    html = render_selector(options: [])
    assert html =~ ~s(id="example-model-select")
    refute html =~ "Enter the model ID"
  end

  test "model locking leaves provider selectable and preserves submitted values" do
    document = render_selector(model_disabled: true) |> LazyHTML.from_fragment()
    assert Enum.any?(LazyHTML.query(document, "fieldset[disabled] #example-model-select"))
    assert Enum.empty?(LazyHTML.query(document, "fieldset[disabled] #example-credential-select"))
  end

  test "unselected model has a placeholder instead of stale capabilities" do
    html = render_selector(form: to_form(%{"credential_id" => "12", "model" => ""}, as: :example))
    assert html =~ "Select a model to view modalities"
    refute html =~ "Input: Text"
  end

  test "native provider variant preserves field names and selection" do
    document = render_selector(native_credential: true) |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query(document, "select[name='example[credential_id]'] option[selected]"),
             "value"
           ) == ["12"]
  end

  test "validation errors stay attached to their controls" do
    form =
      to_form(%{"credential_id" => "12", "model" => ""},
        as: :example,
        errors: [credential_id: {"is unavailable", []}, model: {"can't be blank", []}]
      )

    document = render_selector(form: form) |> LazyHTML.from_fragment()

    assert LazyHTML.text(LazyHTML.query(document, ".zaq-ai-model-provider .zaq-field-error")) =~
             "is unavailable"

    assert LazyHTML.text(LazyHTML.query(document, ".zaq-ai-model-field .zaq-field-error")) =~
             "can't be blank"
  end

  property "manual models preserve arbitrary IDs without inventing modalities" do
    check all(model_id <- string(:alphanumeric, min_length: 1)) do
      html =
        render_selector(
          form: to_form(%{"credential_id" => "12", "model" => model_id}, as: :example),
          options: [],
          model_catalogs: %{"12" => []}
        )

      input = LazyHTML.from_fragment(html) |> LazyHTML.query("#example-model-input")
      assert LazyHTML.attribute(input, "value") == [model_id]
      assert html =~ "Input: Unknown"
      assert html =~ "Output: Unknown"
    end
  end

  defp render_selector(overrides) do
    defaults = [
      id_prefix: "example",
      form: to_form(%{"credential_id" => "12", "model" => "text-model"}, as: :example),
      credential_options: [{"Provider", "12"}],
      options: [{"Text model", "text-model"}],
      model_catalogs: %{
        "12" => [%{id: "text-model", modalities: %{input: [:text], output: [:text]}}]
      }
    ]

    render_component(&AIModelSelector.ai_model_selector/1, Keyword.merge(defaults, overrides))
  end
end
