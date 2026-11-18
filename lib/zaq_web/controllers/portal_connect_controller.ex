defmodule ZaqWeb.PortalConnectController do
  use ZaqWeb, :controller

  alias Zaq.Accounts
  alias Zaq.Accounts.PasswordPolicy
  alias Zaq.UserPortal.Onboarding
  alias ZaqWeb.BOSession

  @token_salt "portal bootstrap link"
  @token_max_age 600

  plug :private_setup_page

  def new(conn, %{"portal_token" => token})
      when is_binary(token) and byte_size(token) in 1..2048 do
    case Accounts.bootstrap_admin_pending_onboarding() do
      %{id: id, must_change_password: true} ->
        conn
        |> put_session(:portal_setup, Phoenix.Token.encrypt(conn, @token_salt, {id, token}))
        |> redirect(to: ~p"/bo/connect")

      _ ->
        unavailable(conn)
    end
  end

  def new(conn, %{"portal_token" => _}), do: unavailable(conn)

  def new(conn, _params) do
    case pending_setup(conn) do
      {:ok, _user, _token} -> render(conn, :new, error: nil)
      _ -> unavailable(conn)
    end
  end

  def create(conn, params) do
    with {:ok, user, token} <- pending_setup(conn),
         {:ok, password} <- validate_password(params) do
      case Onboarding.connect_bootstrap(user, token, password) do
        {:ok, user, job_id, confirmation} ->
          conn
          |> complete_session(user)
          |> report_confirmation(confirmation)
          |> redirect(to: ~p"/bo/connect/status/#{job_id}")

        {:error, reason} when reason in [:installation_enqueue_failed, :local_setup_failed] ->
          conn
          |> delete_session(:portal_setup)
          |> form_error(message(reason))

        {:error, :bootstrap_unavailable} ->
          unavailable(conn)

        {:error, reason} ->
          form_error(conn, message(reason))
      end
    else
      {:error, :setup_unavailable} -> unavailable(conn)
      {:error, reason} -> form_error(conn, message(reason))
    end
  end

  defp pending_setup(conn) do
    with encrypted when is_binary(encrypted) <- get_session(conn, :portal_setup),
         {:ok, {id, token}} <-
           Phoenix.Token.decrypt(conn, @token_salt, encrypted, max_age: @token_max_age),
         %{id: ^id, must_change_password: true} = user <-
           Accounts.bootstrap_admin_pending_onboarding() do
      {:ok, user, token}
    else
      _ -> {:error, :setup_unavailable}
    end
  end

  defp validate_password(%{"password" => password, "password_confirmation" => password})
       when is_binary(password) do
    unmet = password |> PasswordPolicy.requirements_with_status() |> Enum.reject(& &1.met?)

    case unmet do
      [] -> {:ok, password}
      requirements -> {:error, {:weak_password, Enum.map(requirements, & &1.label)}}
    end
  end

  defp validate_password(_), do: {:error, :password_mismatch}

  defp complete_session(conn, user) do
    conn
    |> delete_session(:portal_setup)
    |> BOSession.sign_in(user)
  end

  defp report_confirmation(conn, :ok), do: conn

  defp report_confirmation(conn, {:error, _}) do
    put_flash(
      conn,
      :error,
      "ZAQ setup can continue, but the Portal did not acknowledge the connection."
    )
  end

  defp unavailable(conn) do
    conn
    |> delete_session(:portal_setup)
    |> redirect(to: ~p"/bo/login")
  end

  defp private_setup_page(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp form_error(conn, message) do
    conn |> put_status(:unprocessable_entity) |> render(:new, error: message)
  end

  defp message(:password_mismatch), do: "Passwords do not match."

  defp message({:weak_password, labels}),
    do: "Password requirements not met: #{Enum.join(labels, "; ")}."

  defp message({:portal_status, status}) when status in 400..499,
    do: "The Portal rejected this link. Get a new link and try again."

  defp message(:invalid_portal_response),
    do: "The Portal returned incomplete or invalid setup details."

  defp message(:registration_failed),
    do: "ZAQ could not complete registration. Get a new link and try again."

  defp message(:installation_enqueue_failed),
    do: "ZAQ couldn’t queue setup. Return to Portal and request a new connection link."

  defp message(:local_setup_failed),
    do:
      "ZAQ couldn’t finish local setup. Check your configuration and request a new connection link."

  defp message(_), do: "Could not connect to the Portal. Try again."
end
