# lib/zaq_web/live/bo/change_password_live.ex

defmodule ZaqWeb.Live.BO.ChangePasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts

  def mount(_params, session, socket) do
    user = Accounts.get_user!(session["user_id"])

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:form, to_form(%{"password" => "", "password_confirmation" => ""}))
     |> assign(:error_message, nil)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  def handle_event(
        "change_password",
        %{"password" => password, "password_confirmation" => confirmation},
        socket
      ) do
    if password != confirmation do
      {:noreply, assign(socket, :error_message, "Passwords do not match")}
    else
      socket
      |> update_password(password)
      |> then(&{:noreply, &1})
    end
  end

  defp update_password(socket, password) do
    case Accounts.change_password(socket.assigns.user, %{password: password}) do
      {:ok, _user} ->
        socket
        |> put_flash(:info, "Password changed successfully")
        |> push_navigate(to: ~p"/bo/dashboard")

      {:error, changeset} ->
        assign(socket, :error_message, format_changeset_errors(changeset))
    end
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end
end
