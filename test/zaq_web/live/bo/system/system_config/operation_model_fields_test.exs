defmodule ZaqWeb.Live.BO.System.SystemConfig.OperationModelFieldsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Zaq.System.OperationModelConfig
  alias ZaqWeb.Live.BO.System.SystemConfig.OperationModelFields

  test "credential validation error stays with the credential control" do
    changeset =
      %OperationModelConfig{}
      |> OperationModelConfig.changeset(%{model: "gpt-custom"})
      |> Map.put(:action, :validate)

    html = render_fields(changeset, [], [{"API credential", "12"}])
    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query(".zaq-field-error")
           |> LazyHTML.text()
           |> String.trim() == "can't be blank"

    refute field_error(document, "model") =~ "can't be blank"
    assert LazyHTML.query(document, "#translation-credential-select") |> Enum.any?()
  end

  test "configured credential without catalog options renders editable custom model" do
    changeset =
      OperationModelConfig.changeset(%OperationModelConfig{}, %{
        credential_id: 12,
        model: "vendor/model-v2"
      })

    html = render_fields(changeset, [])
    document = LazyHTML.from_fragment(html)

    input = LazyHTML.query(document, "input[type='text'][name='operation_model_config[model]']")
    assert LazyHTML.attribute(input, "value") == ["vendor/model-v2"]
    assert html =~ "Enter the model ID for custom endpoints without a model catalog."
    assert LazyHTML.query(document, "#translation-model-select") |> Enum.empty?()

    invalid =
      %OperationModelConfig{}
      |> OperationModelConfig.changeset(%{credential_id: 12})
      |> Map.put(:action, :validate)
      |> Map.update!(:params, &Map.put(&1, "model", ""))

    invalid_html = render_fields(invalid, [])
    invalid_document = LazyHTML.from_fragment(invalid_html)
    assert field_error(invalid_document, "model") == "can't be blank"
  end

  test "catalog options use searchable select and unconfigured empty catalog stays non-manual" do
    configured =
      OperationModelConfig.changeset(%OperationModelConfig{}, %{
        credential_id: 12,
        model: "catalog/model"
      })

    html = render_fields(configured, [{"Catalog model", "catalog/model"}])
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#translation-model-select") |> Enum.any?()
    assert html =~ "Catalog model"

    assert Enum.empty?(
             LazyHTML.query(document, "input[type='text'][name='operation_model_config[model]']")
           )

    refute html =~ "Enter the model ID for custom endpoints without a model catalog."

    unconfigured = OperationModelConfig.changeset(%OperationModelConfig{}, %{})
    unconfigured_html = render_fields(unconfigured, [])
    unconfigured_document = LazyHTML.from_fragment(unconfigured_html)
    assert LazyHTML.query(unconfigured_document, "#translation-model-select") |> Enum.any?()

    assert Enum.empty?(
             LazyHTML.query(
               unconfigured_document,
               "input[type='text'][name='operation_model_config[model]']"
             )
           )
  end

  defp render_fields(changeset, options, credential_options \\ []) do
    render_component(&OperationModelFields.selection_form/1,
      kind: :translation,
      form: to_form(changeset, as: :operation_model_config),
      options: options,
      credential_options: credential_options,
      title: "Translation"
    )
  end

  defp field_error(document, field) do
    document
    |> LazyHTML.query(field_error_selector(field))
    |> LazyHTML.text()
    |> String.trim()
  end

  defp field_error_selector("credential_id"),
    do: ".zaq-field-row-block:has(#translation-credential-select) .zaq-field-error"

  defp field_error_selector(field),
    do: ".zaq-field-row-block:has(input[name$='[#{field}]']) .zaq-field-error"
end
