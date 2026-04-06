defmodule ZaqWeb.Live.BO.System.PeopleLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.SearchableSelect

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Accounts.Team

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/bo/people")
     |> assign(:people, People.list_people())
     |> assign(:teams, People.list_teams())
     |> assign(:active_tab, :people)
     |> assign(:loading, false)
     |> assign(:error, nil)
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:modal, nil)
     |> assign(:modal_entity, nil)
     |> assign(:modal_parent_id, nil)
     |> assign(:modal_changeset, nil)
     |> assign(:modal_errors, [])
     |> assign(:confirm_delete, nil)}
  end

  # ── Tab ─────────────────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, String.to_existing_atom(tab))
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:confirm_delete, nil)}
  end

  # ── People selection ─────────────────────────────────────────────────────

  def handle_event("select_person", %{"id" => id}, socket) do
    person = People.get_person_with_channels!(id)

    {:noreply,
     socket
     |> assign(:selected_person, person)
     |> assign(:person_channels, person.channels)
     |> assign(:confirm_delete, nil)}
  end

  def handle_event("deselect_person", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:confirm_delete, nil)}
  end

  # ── Modal open ───────────────────────────────────────────────────────────

  def handle_event(
        "open_modal",
        %{"action" => action, "entity" => "person"} = params,
        socket
      ) do
    changeset =
      case action do
        "edit" ->
          person = People.get_person!(params["id"])
          Person.update_changeset(person, %{})

        _ ->
          Person.changeset(%Person{}, %{})
      end

    {:noreply,
     socket
     |> assign(:modal, String.to_existing_atom(action))
     |> assign(:modal_entity, :person)
     |> assign(:modal_parent_id, nil)
     |> assign(:modal_changeset, changeset)
     |> assign(:modal_errors, [])}
  end

  def handle_event(
        "open_modal",
        %{"action" => action, "entity" => "channel"} = params,
        socket
      ) do
    changeset =
      case action do
        "edit" ->
          channel =
            Enum.find(socket.assigns.person_channels, &(&1.id == String.to_integer(params["id"])))

          PersonChannel.update_changeset(channel, %{})

        _ ->
          PersonChannel.changeset(%PersonChannel{}, %{})
      end

    {:noreply,
     socket
     |> assign(:modal, String.to_existing_atom(action))
     |> assign(:modal_entity, :channel)
     |> assign(:modal_parent_id, params["parent_id"])
     |> assign(:modal_changeset, changeset)
     |> assign(:modal_errors, [])}
  end

  def handle_event(
        "open_modal",
        %{"action" => action, "entity" => "team"} = params,
        socket
      ) do
    changeset =
      case action do
        "edit" ->
          team = People.get_team!(params["id"])
          Team.update_changeset(team, %{})

        _ ->
          Team.changeset(%Team{}, %{})
      end

    {:noreply,
     socket
     |> assign(:modal, String.to_existing_atom(action))
     |> assign(:modal_entity, :team)
     |> assign(:modal_parent_id, nil)
     |> assign(:modal_changeset, changeset)
     |> assign(:modal_errors, [])}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, nil)
     |> assign(:modal_entity, nil)
     |> assign(:modal_parent_id, nil)
     |> assign(:modal_changeset, nil)
     |> assign(:modal_errors, [])}
  end

  # ── Validate ─────────────────────────────────────────────────────────────

  def handle_event("validate", %{"person" => attrs}, socket) do
    changeset =
      case socket.assigns.modal do
        :edit -> Person.update_changeset(socket.assigns.modal_changeset.data, attrs)
        _ -> Person.changeset(%Person{}, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :modal_changeset, changeset)}
  end

  def handle_event("validate", %{"channel" => attrs}, socket) do
    changeset =
      case socket.assigns.modal do
        :edit -> PersonChannel.update_changeset(socket.assigns.modal_changeset.data, attrs)
        _ -> PersonChannel.changeset(%PersonChannel{}, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :modal_changeset, changeset)}
  end

  def handle_event("validate", %{"team" => attrs}, socket) do
    changeset =
      case socket.assigns.modal do
        :edit -> Team.update_changeset(socket.assigns.modal_changeset.data, attrs)
        _ -> Team.changeset(%Team{}, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :modal_changeset, changeset)}
  end

  # ── Save ─────────────────────────────────────────────────────────────────

  def handle_event("save", %{"person" => attrs}, socket) do
    result =
      case socket.assigns.modal do
        :edit -> People.update_person(socket.assigns.modal_changeset.data, attrs)
        _ -> People.create_person(attrs)
      end

    case result do
      {:ok, _person} ->
        people = People.list_people()

        selected =
          if socket.assigns.selected_person do
            People.get_person_with_channels!(socket.assigns.selected_person.id)
          end

        {:noreply,
         socket
         |> assign(:people, people)
         |> assign(:selected_person, selected)
         |> assign(:person_channels, if(selected, do: selected.channels, else: []))
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  def handle_event("save", %{"channel" => attrs}, socket) do
    person_id = socket.assigns.modal_parent_id || socket.assigns.selected_person.id

    result =
      case socket.assigns.modal do
        :edit ->
          People.update_channel(socket.assigns.modal_changeset.data, attrs)

        _ ->
          attrs
          |> Map.put("person_id", person_id)
          |> People.add_channel()
      end

    case result do
      {:ok, _channel} ->
        person = People.get_person_with_channels!(person_id)

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_channels, person.channels)
         |> assign(:people, People.list_people())
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    result =
      case socket.assigns.modal do
        :edit -> People.update_team(socket.assigns.modal_changeset.data, attrs)
        _ -> People.create_team(attrs)
      end

    case result do
      {:ok, _team} ->
        {:noreply,
         socket
         |> assign(:teams, People.list_teams())
         |> assign(:people, People.list_people())
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  # ── Delete ───────────────────────────────────────────────────────────────

  def handle_event("confirm_delete", %{"entity" => entity, "id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete, %{entity: entity, id: id})}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event(
        "delete",
        _params,
        %{assigns: %{confirm_delete: %{entity: "person", id: id}}} = socket
      ) do
    person = People.get_person!(id)

    case People.delete_person(person) do
      {:ok, _} ->
        deselect =
          socket.assigns.selected_person && to_string(socket.assigns.selected_person.id) == id

        {:noreply,
         socket
         |> assign(:people, People.list_people())
         |> assign(:selected_person, if(deselect, do: nil, else: socket.assigns.selected_person))
         |> assign(:person_channels, if(deselect, do: [], else: socket.assigns.person_channels))
         |> assign(:confirm_delete, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event(
        "delete",
        _params,
        %{assigns: %{confirm_delete: %{entity: "channel", id: id}}} = socket
      ) do
    channel = Enum.find(socket.assigns.person_channels, &(to_string(&1.id) == id))

    case People.delete_channel(channel) do
      {:ok, _} ->
        person = People.get_person_with_channels!(socket.assigns.selected_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_channels, person.channels)
         |> assign(:people, People.list_people())
         |> assign(:confirm_delete, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event(
        "delete",
        _params,
        %{assigns: %{confirm_delete: %{entity: "team", id: id}}} = socket
      ) do
    team = People.get_team!(id)

    case People.delete_team(team) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:teams, People.list_teams())
         |> assign(:people, People.list_people())
         |> assign(:confirm_delete, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  # ── Channel reorder ───────────────────────────────────────────────────────

  def handle_event("move_channel_up", %{"channel_id" => channel_id}, socket) do
    channels = socket.assigns.person_channels
    idx = Enum.find_index(channels, &(to_string(&1.id) == channel_id))

    if idx && idx > 0 do
      current = Enum.at(channels, idx)
      previous = Enum.at(channels, idx - 1)
      People.swap_channel_weights(current, previous)
      person = People.get_person_with_channels!(socket.assigns.selected_person.id)

      {:noreply,
       socket
       |> assign(:selected_person, person)
       |> assign(:person_channels, person.channels)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_channel_down", %{"channel_id" => channel_id}, socket) do
    channels = socket.assigns.person_channels
    idx = Enum.find_index(channels, &(to_string(&1.id) == channel_id))

    if idx && idx < length(channels) - 1 do
      current = Enum.at(channels, idx)
      next = Enum.at(channels, idx + 1)
      People.swap_channel_weights(current, next)
      person = People.get_person_with_channels!(socket.assigns.selected_person.id)

      {:noreply,
       socket
       |> assign(:selected_person, person)
       |> assign(:person_channels, person.channels)}
    else
      {:noreply, socket}
    end
  end

  # ── Team assignment ───────────────────────────────────────────────────────

  def handle_event("assign_team_select", %{"team_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("assign_team_select", %{"team_id" => team_id_str}, socket) do
    team_id = String.to_integer(team_id_str)
    person = socket.assigns.selected_person

    case People.assign_team(person, team_id) do
      {:ok, updated_person} ->
        person_with_channels = People.get_person_with_channels!(updated_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person_with_channels)
         |> assign(:person_channels, person_with_channels.channels)
         |> assign(:people, People.list_people())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_team", %{"team_id" => team_id_str}, socket) do
    team_id = String.to_integer(team_id_str)
    person = socket.assigns.selected_person

    result =
      if team_id in person.team_ids do
        People.unassign_team(person, team_id)
      else
        People.assign_team(person, team_id)
      end

    case result do
      {:ok, updated_person} ->
        person_with_channels = People.get_person_with_channels!(updated_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person_with_channels)
         |> assign(:person_channels, person_with_channels.channels)
         |> assign(:people, People.list_people())}

      {:error, _} ->
        {:noreply, socket}
    end
  end
end
