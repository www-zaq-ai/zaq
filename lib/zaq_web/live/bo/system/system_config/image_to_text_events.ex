defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextEvents do
  @moduledoc """
  Helpers for image-to-text form updates.
  """

  alias Zaq.System.ImageToTextConfig

  def validate_form(socket, cfg, params, provider_id, model_options_fun)
      when is_function(model_options_fun, 1) do
    changeset =
      cfg
      |> ImageToTextConfig.changeset(params)
      |> Map.put(:action, :validate)

    socket
    |> Phoenix.Component.assign(:image_to_text_model_options, model_options_fun.(provider_id))
    |> Phoenix.Component.assign(
      :image_to_text_form,
      Phoenix.Component.to_form(changeset, as: :image_to_text_config)
    )
  end

  def apply_save_error(socket, %Ecto.Changeset{} = changeset) do
    Phoenix.Component.assign(
      socket,
      :image_to_text_form,
      Phoenix.Component.to_form(Map.put(changeset, :action, :validate), as: :image_to_text_config)
    )
  end
end
