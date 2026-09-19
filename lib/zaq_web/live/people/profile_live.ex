defmodule ZaqWeb.Live.People.ProfileLive do
  @moduledoc "Authenticated self-service profile and atomic channel priorities through the confidential Engine boundary."
  use ZaqWeb, :live_view
  alias Zaq.Engine.{Events, PeopleProfile}
  alias ZaqWeb.ChannelOrder
  alias ZaqWeb.Components.DesignSystem.{Button, PersonHeader, PersonProfile}
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> put_private(:person_profile_token, session["person_session_token"])
     |> assign(page_title: "Profile", profile: nil, editable: false, mode: :read)
     |> load_profile()}
  end

  @impl true
  def handle_event(event, params, socket) do
    # The route hook has just refreshed these grants. Remove stale affordances on
    # any event, including delayed drag/change events, rather than only on Save.
    permissions = socket.assigns[:person_permissions]

    if permissions && !editable?(permissions) && socket.assigns.editable do
      {:noreply, revoked(socket)}
    else
      edit_event(event, params, socket)
    end
  end

  defp edit_event("retry", _, socket), do: {:noreply, load_profile(socket)}

  defp edit_event(event, _, %{assigns: %{mode: :read}} = socket)
       when event in ["edit_name", "edit_order"] do
    socket = load_profile(socket)

    cond do
      !socket.assigns.editable ->
        {:noreply, socket}

      event == "edit_name" ->
        {:noreply, socket |> assign(mode: :name) |> focus("profile-name")}

      length(socket.assigns.profile.channels) > 1 ->
        {:noreply, socket |> assign(mode: :order) |> focus("order-instructions")}

      true ->
        {:noreply, socket}
    end
  end

  defp edit_event("cancel", _, socket) do
    target = if socket.assigns.mode == :name, do: "edit-name", else: "edit-order"
    {:noreply, socket |> clear_flash() |> load_profile() |> focus(target)}
  end

  defp edit_event(
         "validate_name",
         %{"profile" => %{"full_name" => name}},
         %{assigns: %{mode: :name}} = socket
       )
       when is_binary(name) do
    {:noreply,
     assign(socket, name_form: to_form(%{"full_name" => name}, as: :profile), name_errors: [])}
  end

  defp edit_event(
         "save_profile",
         %{"profile" => attrs},
         %{assigns: %{mode: :name, editable: true}} = socket
       )
       when is_map(attrs) do
    socket =
      if is_binary(attrs["full_name"]),
        do:
          assign(socket, name_form: to_form(%{"full_name" => attrs["full_name"]}, as: :profile)),
        else: socket

    result = command(socket, :update_self_profile, %{attrs: Map.take(attrs, ["full_name"])})
    {:noreply, save_result(socket, result, "Profile saved.", "edit-name")}
  end

  defp edit_event(
         "move_channel",
         %{"id" => id} = params,
         %{assigns: %{mode: :order, editable: true}} = socket
       ) do
    channels =
      ChannelOrder.move(socket.assigns.draft_channels, id, params["action"] || params["target"])

    if channels == socket.assigns.draft_channels do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(
         draft_channels: channels,
         announcement: ChannelOrder.announcement(channels, id)
       )
       |> focus("channel-priority-#{id}")}
    end
  end

  defp edit_event("save_order", _, %{assigns: %{mode: :order, editable: true}} = socket) do
    # IDs come only from the server-owned draft; the original snapshot is never
    # replaced with current data before the gateway compares it under locks.
    params = %{
      ids: Enum.map(socket.assigns.draft_channels, & &1.channel_id),
      expected: snapshot(socket.assigns.profile)
    }

    result = command(socket, :update_self_channel_order, params)
    {:noreply, save_result(socket, result, "Contact preferences saved.", "edit-order")}
  end

  defp edit_event(event, _, socket)
       when event in ["move_channel", "save_order", "edit_name", "edit_order", "validate_name"],
       do: {:noreply, socket}

  defp edit_event(_, _, socket),
    do:
      {:noreply,
       socket
       |> load_profile()
       |> put_flash(:error, "Unable to save. Please review your edit permission and try again.")}

  defp command(socket, op, params \\ %{}) do
    Events.build_and_dispatch_invoke_event(
      Map.merge(params, %{op: op, token: socket.private.person_profile_token}),
      :people_auth,
      event_opts: [confidential: true]
    ).response
  rescue
    # Database/transport exceptions can contain request data. Never log or render
    # their payload; use the same authoritative reload as tagged unavailability.
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp load_profile(socket) do
    case command(socket, :profile) do
      {:ok, %PeopleProfile{} = profile} -> assign_profile(socket, profile)
      error -> load_error(socket, error)
    end
  end

  defp assign_profile(socket, profile) do
    assign(socket,
      profile: profile,
      current_person:
        Map.put(socket.assigns[:current_person] || %{}, :full_name, profile.person.full_name),
      person_permissions: profile.permissions,
      editable: editable?(profile.permissions),
      mode: :read,
      name_form: to_form(%{"full_name" => profile.person.full_name || ""}, as: :profile),
      name_errors: [],
      draft_channels: display_channels(profile.channels),
      announcement: ""
    )
  end

  defp editable?(permissions),
    do: Enum.all?([:access_profile, :edit_profile], &MapSet.member?(permissions, &1))

  defp save_result(socket, {:ok, %PeopleProfile{} = profile}, message, target),
    do:
      socket
      |> clear_flash()
      |> assign_profile(profile)
      |> put_flash(:info, message)
      |> focus(target)

  defp save_result(socket, {:error, %Ecto.Changeset{} = changeset}, _, _) do
    submitted = Map.get(changeset.params || %{}, "full_name")

    value =
      if is_binary(submitted) or is_number(submitted),
        do: submitted,
        else: socket.assigns.name_form[:full_name].value

    socket
    |> clear_flash()
    |> assign(
      name_form: to_form(%{"full_name" => value}, as: :profile),
      name_errors:
        Enum.map(
          Keyword.get_values(changeset.errors, :full_name),
          &ZaqWeb.CoreComponents.translate_error/1
        )
    )
    |> focus("profile-name")
  end

  defp save_result(socket, {:error, :forbidden}, _, _), do: revoked(socket)

  defp save_result(socket, {:error, reason}, _, _) when reason in [:stale_order, :not_found],
    do: stale(socket)

  defp save_result(socket, {:error, :invalid_session} = error, _, _),
    do: load_error(socket, error)

  defp save_result(socket, _, _, _) do
    case command(socket, :profile) do
      {:ok, profile} -> recover_draft(socket, profile)
      error -> load_error(socket, error)
    end
  end

  defp recover_draft(socket, profile) do
    cond do
      !editable?(profile.permissions) ->
        revoked(socket)

      socket.assigns.mode == :order && snapshot(profile) != snapshot(socket.assigns.profile) ->
        stale(socket)

      true ->
        socket
        |> assign(profile: profile)
        |> put_flash(:error, "Unable to save. Your draft is kept. Please try again or cancel.")
    end
  end

  defp revoked(socket),
    do:
      socket
      |> load_profile()
      |> put_flash(:error, "You no longer have permission to edit this profile.")

  defp stale(socket),
    do:
      socket
      |> load_profile()
      |> put_flash(
        :error,
        "Your channels changed since you started editing. Review the current contact priority and try again."
      )
      |> focus("edit-order")

  defp snapshot(profile), do: Enum.map(profile.channels, &Map.take(&1, [:id, :weight]))
  defp focus(socket, id), do: push_event(socket, "profile-focus", %{id: id})

  defp load_error(socket, {:error, :invalid_session}), do: redirect(socket, to: "/people/login")

  defp load_error(socket, _) do
    socket
    |> assign(profile: nil, editable: false, mode: :read, draft_channels: [], name_errors: [])
    |> put_flash(:error, "Your profile is unavailable. Please try again.")
  end

  defp display_channels(channels) do
    Enum.map(channels, fn channel ->
      %{
        id: to_string(channel.id),
        channel_id: channel.id,
        provider: if(channel.platform == "microsoft_teams", do: "teams", else: channel.platform),
        platform: channel.platform,
        identifier: channel.channel_identifier
      }
    end)
  end

  defp presentation(profile, editable) do
    %{
      person: profile.person,
      editable: editable,
      teams: profile.teams |> Enum.map(& &1.name) |> Enum.sort_by(&String.downcase/1),
      channels: display_channels(profile.channels)
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :person_permissions, fn -> MapSet.new() end)
    assigns = assign_new(assigns, :current_person, fn -> nil end)

    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated content_width={:wide}>
      <:header>
        <PersonHeader.person_header
          history_access={
            Enum.all?(
              [:access_profile, :access_message_history],
              &MapSet.member?(@person_permissions, &1)
            )
          }
          display_name={@current_person && @current_person.full_name}
          title="Profile"
          description="Your details, your teams, and how ZAQ can reach you."
        />
      </:header>
      <p :if={@profile && !@editable} class="zaq-text-body" role="status">
        This profile is read-only. Contact your administrator to request edit permission.
      </p>
      <PersonProfile.person_profile
        :if={@profile}
        profile={presentation(@profile, @editable)}
        mode={@mode}
        name_form={@name_form}
        name_errors={@name_errors}
        draft_channels={@draft_channels}
        announcement={@announcement}
      />
      <Button.button :if={!@profile} variant={:secondary} phx-click="retry">Retry</Button.button>
    </PersonLayout.person_layout>
    """
  end
end
