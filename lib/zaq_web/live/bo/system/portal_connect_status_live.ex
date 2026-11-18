defmodule ZaqWeb.Live.BO.System.PortalConnectStatusLive do
  @moduledoc "Shows the authenticated administrator the result of Portal installation settings."
  use ZaqWeb, :live_view

  alias Zaq.Repo
  alias Zaq.UserPortal.InstallationWorker
  alias ZaqWeb.Components.BOLayout
  alias ZaqWeb.Components.DesignSystem.Button

  @active_states ~w(available scheduled executing retryable)
  @failed_states ~w(discarded cancelled)

  @impl true
  def mount(%{"job_id" => job_id}, _session, socket) do
    user = socket.assigns.current_user
    worker = Oban.Worker.to_string(InstallationWorker)

    with {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 <- Integer.parse(job_id),
         %Oban.Job{worker: ^worker, meta: %{"admin_id" => admin_id}} = job <-
           Repo.get(Oban.Job, id),
         true <- admin_id == user.id do
      socket =
        assign(socket, current_path: ~p"/bo/connect/status/#{id}", job: job, retry_error: nil)

      {:ok, refresh(socket, job)}
    else
      _ -> {:ok, redirect(socket, to: ~p"/bo/dashboard")}
    end
  end

  @impl true
  def handle_info(:refresh_installation, socket) do
    {:noreply, refresh(socket, Repo.get(Oban.Job, socket.assigns.job.id))}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    case Repo.get(Oban.Job, socket.assigns.job.id) do
      %Oban.Job{state: state} = job when state in @failed_states ->
        case Oban.retry_job(job) do
          :ok -> handle_info(:refresh_installation, assign(socket, retry_error: nil))
          {:error, _} -> {:noreply, assign(socket, retry_error: "Could not queue the retry.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp refresh(socket, nil), do: redirect(socket, to: ~p"/bo/dashboard")

  defp refresh(socket, %Oban.Job{state: "completed"}) do
    if connected?(socket),
      do: push_navigate(socket, to: ~p"/bo/ingestion"),
      else: redirect(socket, to: ~p"/bo/ingestion")
  end

  defp refresh(socket, job) do
    if connected?(socket) and active?(job) do
      Process.send_after(self(), :refresh_installation, 1_000)
    end

    assign(socket, job: job)
  end

  defp active?(job), do: job.state in @active_states
  defp failed?(job), do: job.state in @failed_states

  defp installation_error(%Oban.Job{errors: errors}) do
    error = errors |> List.last() |> Kernel.||(%{}) |> Map.get("error", "")

    cond do
      String.contains?(error, ":global_url") ->
        "Could not save the Global URL."

      String.contains?(error, ":screenshot_folder") ->
        "Could not create the screenshot folder on Disk."

      String.contains?(error, ":skills_folder") ->
        "Could not create the Skills folder on Disk."

      String.contains?(error, ":screenshot_destination") ->
        "Could not save the screenshot destination."

      String.contains?(error, ":skills_destination") ->
        "Could not save the Skills destination."

      String.contains?(error, ":disk") ->
        "Could not enable Disk. Check the configured storage base path."

      true ->
        "ZAQ could not apply the installation settings."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      flash={@flash}
      page_title="Portal setup"
      current_path={@current_path}
      features_version={@features_version}
    >
      <div class="zaq-card-default zaq-layout-stack">
        <p :if={active?(@job)} role="status" class="zaq-text-body">
          <.icon
            name="hero-arrow-path"
            class="zaq-icon-sm motion-safe:animate-spin"
          />
          {if @job.state == "retryable",
            do: "Waiting to retry installation settings…",
            else: "Applying installation settings…"}
        </p>
        <p
          :if={failed?(@job) or @job.errors != []}
          role="alert"
          class="zaq-feedback-banner zaq-danger zaq-text-body"
        >
          {installation_error(@job)}
        </p>
        <p :if={@retry_error} role="alert" class="zaq-feedback-banner zaq-danger zaq-text-body">
          {@retry_error}
        </p>
        <Button.button :if={failed?(@job)} phx-click="retry" variant={:primary}>
          Retry configuration
        </Button.button>
      </div>
    </BOLayout.bo_layout>
    """
  end
end
