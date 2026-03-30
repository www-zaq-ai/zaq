defmodule ZaqWeb.Live.BO.Accounts.FormFlow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  @type form_action_opts :: [
          assign_key: atom(),
          new_title: String.t(),
          edit_title: String.t(),
          new_entity: (-> struct()),
          load_entity: (String.t() -> struct()),
          changeset: (struct(), map() -> Ecto.Changeset.t())
        ]

  @spec assign_entity_form(Phoenix.LiveView.Socket.t(), atom(), map(), form_action_opts()) ::
          Phoenix.LiveView.Socket.t()
  def assign_entity_form(socket, action, params, opts) do
    {title, entity} =
      case action do
        :new ->
          {Keyword.fetch!(opts, :new_title), Keyword.fetch!(opts, :new_entity).()}

        :edit ->
          {Keyword.fetch!(opts, :edit_title), Keyword.fetch!(opts, :load_entity).(params["id"])}
      end

    changeset = Keyword.fetch!(opts, :changeset).(entity, %{})

    socket
    |> assign(:page_title, title)
    |> assign(Keyword.fetch!(opts, :assign_key), entity)
    |> assign(:form, Phoenix.Component.to_form(changeset))
  end

  @spec handle_save_result(
          Phoenix.LiveView.Socket.t(),
          {:ok, any()} | {:error, Ecto.Changeset.t()},
          keyword()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_result(socket, result, opts) do
    case result do
      {:ok, _entity} ->
        {:noreply,
         socket
         |> put_flash(:info, Keyword.fetch!(opts, :success_message))
         |> push_navigate(to: Keyword.fetch!(opts, :to))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, Phoenix.Component.to_form(changeset))}
    end
  end
end
