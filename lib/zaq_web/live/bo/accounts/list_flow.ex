defmodule ZaqWeb.Live.BO.Accounts.ListFlow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  @type delete_opts :: [
          fetch: (String.t() -> struct()),
          delete: (struct() -> {:ok, any()} | {:error, any()}),
          reload: (-> list()),
          assign_key: atom(),
          success_message: String.t(),
          error_message: String.t()
        ]

  @spec handle_delete(Phoenix.LiveView.Socket.t(), String.t(), delete_opts()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete(socket, id, opts) do
    entity = Keyword.fetch!(opts, :fetch).(id)

    case Keyword.fetch!(opts, :delete).(entity) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, Keyword.fetch!(opts, :success_message))
         |> assign(Keyword.fetch!(opts, :assign_key), Keyword.fetch!(opts, :reload).())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, Keyword.fetch!(opts, :error_message))}
    end
  end
end
