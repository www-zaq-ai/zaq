defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextTabTest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Zaq.System.ImageToTextConfig
  alias ZaqWeb.Live.BO.System.SystemConfig.ImageToTextTab

  @model_error "model rejected by provider"

  test "renders catalog model selection and translates its validation error" do
    form = validation_form()

    html =
      render_component(&ImageToTextTab.panel/1,
        form: form,
        credential_options: [{"Provider", "1"}],
        model_options: [{"GPT-4o", "gpt-4o"}]
      )

    doc = LazyHTML.from_fragment(html)

    refute Enum.empty?(LazyHTML.query(doc, "#image-to-text-model-select"))

    assert LazyHTML.text(LazyHTML.query(doc, "#image-to-text-config-form .zaq-field-error"))
           |> String.trim() == @model_error

    assert Enum.empty?(LazyHTML.query(doc, "#image-to-text-credential-select + .zaq-field-error"))
  end

  test "renders a text input without catalog inline model error when options are empty" do
    html =
      render_component(&ImageToTextTab.panel/1,
        form: validation_form(),
        credential_options: [{"Provider", "1"}],
        model_options: []
      )

    doc = LazyHTML.from_fragment(html)

    assert Enum.empty?(LazyHTML.query(doc, "#image-to-text-model-select"))

    refute Enum.empty?(
             LazyHTML.query(
               doc,
               "#image-to-text-config-form input[name='image_to_text_config[model]']"
             )
           )

    refute Enum.empty?(LazyHTML.query(doc, "#image-to-text-config-form .zaq-field-error"))

    assert Enum.empty?(
             LazyHTML.query(doc, "#image-to-text-config-form p.zaq-field-error.zaq-text-caption")
           )
  end

  defp validation_form do
    changeset =
      %ImageToTextConfig{}
      |> ImageToTextConfig.changeset(%{credential_id: 1, model: "gpt-4o"})
      |> Ecto.Changeset.add_error(:model, @model_error)
      |> Map.put(:action, :validate)

    Phoenix.Component.to_form(changeset, as: :image_to_text_config)
  end
end
