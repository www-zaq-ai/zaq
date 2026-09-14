defmodule ZaqWeb.Live.People.ProfileLive do
  @moduledoc "Authenticated self-service profile and channel priorities through the confidential Engine boundary."
  use ZaqWeb, :live_view
  alias Zaq.Engine.{Events, PeopleProfile}
  alias ZaqWeb.Components.DesignSystem.{Button, Input}
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> put_private(:person_profile_token, session["person_session_token"])
      |> assign(page_title: "Profile", profile: nil, editable: false)
      |> load_profile()

    {:ok, socket}
  end

  @impl true
  def handle_event("save_profile", %{"profile" => attrs}, socket) when is_map(attrs) do
    result = command(socket, :update_self_profile, %{attrs: attrs})
    {:noreply, save_result(socket, result, :profile, "Profile saved.")}
  end

  def handle_event("save_channel", %{"channel_id" => id, "channel" => attrs}, socket)
      when is_map(attrs) and (is_binary(id) or is_integer(id)) do
    result = command(socket, :update_self_channel_weight, %{channel_id: id, attrs: attrs})
    {:noreply, save_result(socket, result, {:channel, to_string(id)}, "Priority saved.")}
  end

  def handle_event("retry", _, socket), do: {:noreply, load_profile(socket)}

  def handle_event(_, _, socket),
    do:
      {:noreply,
       socket |> load_profile() |> put_flash(:error, "Unable to save. Please try again.")}

  defp command(socket, op, params \\ %{}) do
    Events.build_and_dispatch_invoke_event(
      Map.merge(params, %{op: op, token: socket.private.person_profile_token}),
      :people_auth,
      event_opts: [confidential: true]
    ).response
  end

  defp load_profile(socket) do
    case command(socket, :profile) do
      {:ok, %PeopleProfile{} = profile} -> assign_profile(socket, profile)
      error -> load_error(socket, error)
    end
  end

  defp assign_profile(socket, profile) do
    channel_forms =
      Map.new(profile.channels, fn channel ->
        {to_string(channel.id),
         to_form(%{"weight" => channel.weight}, as: :channel, id: "channel_#{channel.id}")}
      end)

    assign(socket,
      profile: profile,
      editable:
        Enum.all?([:access_profile, :edit_profile], &MapSet.member?(profile.permissions, &1)),
      profile_form: to_form(%{"full_name" => profile.person.full_name}, as: :profile),
      channel_forms: channel_forms
    )
  end

  defp save_result(socket, {:ok, %PeopleProfile{} = profile}, _, message),
    do: socket |> clear_flash() |> assign_profile(profile) |> put_flash(:info, message)

  defp save_result(socket, {:error, %Ecto.Changeset{} = changeset}, target, _) do
    socket = clear_flash(socket)

    case target do
      :profile ->
        assign(socket, :profile_form, error_form(changeset, :full_name, as: :profile))

      {:channel, id} ->
        assign(
          socket,
          :channel_forms,
          Map.put(
            socket.assigns.channel_forms,
            id,
            error_form(changeset, :weight, as: :channel, id: "channel_#{id}")
          )
        )
    end
  end

  defp save_result(socket, {:error, :forbidden}, _, _),
    do:
      socket
      |> clear_flash()
      |> load_profile()
      |> put_flash(:error, "You no longer have permission to edit this profile.")

  defp save_result(socket, {:error, :not_found}, _, _),
    do:
      socket
      |> clear_flash()
      |> load_profile()
      |> put_flash(:error, "Channel not found. Please review your current channels.")

  defp save_result(socket, error, _, _), do: load_error(socket, error)

  defp error_form(changeset, field, opts) do
    key = Atom.to_string(field)
    submitted = Map.get(changeset.params || %{}, key)

    value =
      if is_binary(submitted) or is_number(submitted),
        do: submitted,
        else: Ecto.Changeset.get_field(changeset, field)

    to_form(%{key => value}, Keyword.put(opts, :errors, changeset.errors))
  end

  defp load_error(socket, {:error, :invalid_session}),
    do: redirect(socket, to: "/people/login")

  defp load_error(socket, _) do
    socket
    |> assign(profile: nil, editable: false)
    |> put_flash(:error, "Your profile is unavailable. Please try again.")
  end

  defp display(value) when value in [nil, ""], do: "Not provided"
  defp display(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated>
      <section :if={@profile} class="zaq-card-default zaq-layout-stack">
        <h1 class="zaq-text-h1">Profile</h1>
        <p class="zaq-text-body">Welcome, {display(@profile.person.full_name)}.</p>
        <.form
          :if={@editable}
          for={@profile_form}
          id="self-profile-form"
          phx-submit="save_profile"
          class="zaq-layout-stack"
        >
          <Input.input field={@profile_form[:full_name]} label="Full name" autocomplete="name" />
          <Button.button type="submit" phx-disable-with="Saving…">Save profile</Button.button>
        </.form>
        <dl class="zaq-layout-stack">
          <div :if={!@editable}>
            <dt class="zaq-text-h4">Full name</dt>
            <dd class="zaq-text-body break-words">{display(@profile.person.full_name)}</dd>
          </div>
          <div :for={
            {field, label} <- [email: "Email", phone: "Phone", role: "Role", status: "Status"]
          }>
            <dt class="zaq-text-h4">{label}</dt>
            <dd class="zaq-text-body break-words">{display(Map.fetch!(@profile.person, field))}</dd>
          </div>
          <div>
            <dt class="zaq-text-h4">Teams</dt>
            <dd :if={@profile.teams == []} class="zaq-text-body">No teams</dd>
            <dd :for={team <- @profile.teams} class="zaq-text-body break-words">{team.name}</dd>
          </div>
        </dl>
        <p :if={!@editable} class="zaq-text-body-sm">
          This profile is read-only. Contact your administrator to request edit permission.
        </p>
      </section>
      <section
        :if={@profile}
        class="zaq-card-default zaq-layout-stack"
        aria-labelledby="channels-heading"
      >
        <h2 id="channels-heading" class="zaq-text-h2">Channels</h2>
        <p id="priority-help" class="zaq-text-body-sm">
          Lower numbers are tried first. Equal priorities keep channel ID order.
        </p>
        <p :if={@profile.channels == []} class="zaq-text-body">No channels</p>
        <div
          :for={channel <- @profile.channels}
          id={"profile-channel-#{channel.id}"}
          class="zaq-layout-stack"
        >
          <h3 class="zaq-text-h3">{channel.platform}</h3>
          <p class="zaq-text-body break-words">{channel.channel_identifier}</p>
          <.form
            :if={@editable}
            for={@channel_forms[to_string(channel.id)]}
            id={"channel-form-#{channel.id}"}
            phx-submit="save_channel"
            class="zaq-layout-stack-tight"
          >
            <Input.input
              type="hidden"
              name="channel_id"
              id={"channel-id-#{channel.id}"}
              value={channel.id}
            />
            <Input.input
              field={@channel_forms[to_string(channel.id)][:weight]}
              type="number"
              min="0"
              step="1"
              label={"Priority for #{channel.platform} / #{channel.channel_identifier}"}
              aria-describedby="priority-help"
            />
            <Button.button
              type="submit"
              variant={:secondary}
              phx-disable-with="Saving…"
              aria-label={"Save priority for #{channel.platform} / #{channel.channel_identifier}"}
            >Save priority</Button.button>
          </.form>
          <p :if={!@editable} class="zaq-text-body">Priority: {channel.weight}</p>
        </div>
      </section>
      <Button.button :if={!@profile} variant={:secondary} phx-click="retry">Retry</Button.button>
    </PersonLayout.person_layout>
    """
  end
end
