defmodule ZaqWeb.Live.BO.System.PeopleLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.DesignSystem.Table, only: [table_selection_bar: 1]
  import ZaqWeb.Components.SearchableSelect

  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Accounts.Team
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.EmptyState
  alias ZaqWeb.Components.DesignSystem.SimplePagination
  alias ZaqWeb.Components.DesignSystem.Toggle, as: DSToggle
  alias ZaqWeb.Live.BO.System.PeopleTable
  alias ZaqWeb.Live.BO.System.TeamsTable

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/bo/people")
      |> assign(:teams, [])
      |> assign(:active_tab, :people)
      |> assign(:loading, false)
      |> assign(:error, nil)
      |> assign(:selected_person, nil)
      |> assign(:person_channels, [])
      |> assign(:person_documents, [])
      |> assign(:modal, nil)
      |> assign(:modal_entity, nil)
      |> assign(:modal_parent_id, nil)
      |> assign(:modal_changeset, nil)
      |> assign(:modal_errors, [])
      |> assign(:confirm_delete, nil)
      |> assign(:selected_people, MapSet.new())
      |> assign(:merge_survivor, nil)
      |> assign(:merge_loser, nil)
      |> assign(:merge_search, "")
      |> assign(:merge_candidates, [])
      |> assign(:filter_name, "")
      |> assign(:filter_email, "")
      |> assign(:filter_phone, "")
      |> assign(:filter_complete, "all")
      |> assign(:filter_team_id, "")
      |> assign(:page, 1)
      |> assign(:per_page, 20)
      |> assign(:total_count, 0)

    {:ok, socket |> refresh_teams() |> refresh_people()}
  end

  def handle_params(%{"person_id" => id}, _uri, socket) do
    case fetch_person_with_channels(id) do
      nil ->
        {:noreply, socket}

      person ->
        person_documents = Ingestion.list_person_permissions(person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_channels, person.channels)
         |> assign(:person_documents, person_documents)
         |> assign(:confirm_delete, nil)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Tab ─────────────────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, String.to_existing_atom(tab))
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:confirm_delete, nil)
     |> assign(:selected_people, MapSet.new())
     |> assign(:merge_survivor, nil)
     |> assign(:merge_loser, nil)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
  end

  # ── Merge ────────────────────────────────────────────────────────────────

  # From incomplete tab — this person is the loser; user picks the survivor to keep
  def handle_event("open_merge_modal", %{"id" => id, "role" => "loser"}, socket) do
    loser = fetch_person_with_channels!(id)

    {:noreply,
     socket
     |> assign(:modal, :merge)
     |> assign(:modal_entity, :merge)
     |> assign(:merge_survivor, nil)
     |> assign(:merge_loser, loser)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
  end

  # From detail panel — this person is the survivor; user picks the loser to absorb
  def handle_event("open_merge_modal", %{"id" => id}, socket) do
    survivor = fetch_person_with_channels!(id)

    {:noreply,
     socket
     |> assign(:modal, :merge)
     |> assign(:modal_entity, :merge)
     |> assign(:merge_survivor, survivor)
     |> assign(:merge_loser, nil)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
  end

  def handle_event("merge_search", %{"merge_search" => query}, socket) do
    candidates =
      if String.length(query) >= 2 do
        exclude_ids =
          [
            socket.assigns.merge_survivor && socket.assigns.merge_survivor.id,
            socket.assigns.merge_loser && socket.assigns.merge_loser.id
          ]
          |> Enum.reject(&is_nil/1)

        search_people(query, exclude_ids)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:merge_search, query)
     |> assign(:merge_candidates, candidates)}
  end

  def handle_event("select_merge_survivor", %{"id" => id}, socket) do
    survivor = fetch_person_with_channels!(id)

    {:noreply,
     socket
     |> assign(:merge_survivor, survivor)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
  end

  def handle_event("select_merge_loser", %{"id" => id}, socket) do
    loser = fetch_person_with_channels!(id)

    {:noreply,
     socket
     |> assign(:merge_loser, loser)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
  end

  def handle_event("confirm_merge", _params, socket) do
    survivor = socket.assigns.merge_survivor
    loser = socket.assigns.merge_loser

    case people_command(:merge, %{survivor_id: survivor.id, loser_id: loser.id}) do
      {:ok, updated_survivor} ->
        {:noreply,
         socket
         |> assign(:selected_person, updated_survivor)
         |> assign(:person_channels, updated_survivor.channels)
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:merge_survivor, nil)
         |> assign(:merge_loser, nil)
         |> refresh_people()
         |> put_flash(:info, "Persons merged successfully.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Merge failed. Please try again.")}
    end
  end

  # ── People selection ─────────────────────────────────────────────────────

  def handle_event("select_person", %{"id" => id}, socket) do
    person = fetch_person_with_channels!(id)
    person_documents = Ingestion.list_person_permissions(person.id)

    {:noreply,
     socket
     |> assign(:selected_person, person)
     |> assign(:person_channels, person.channels)
     |> assign(:person_documents, person_documents)
     |> assign(:confirm_delete, nil)}
  end

  def handle_event("toggle_person_selection", %{"id" => id}, socket) do
    person_id = String.to_integer(id)

    selected_people =
      if MapSet.member?(socket.assigns.selected_people, person_id) do
        MapSet.delete(socket.assigns.selected_people, person_id)
      else
        MapSet.put(socket.assigns.selected_people, person_id)
      end

    {:noreply, assign(socket, :selected_people, selected_people)}
  end

  def handle_event("open_bulk_delete_modal", _params, socket) do
    n = MapSet.size(socket.assigns.selected_people)

    if n == 0 do
      {:noreply, socket}
    else
      confirm = %{
        message: "Delete #{n} selected people? This cannot be undone.",
        event: "confirm_bulk_delete",
        cancel_event: "cancel_bulk_delete"
      }

      {:noreply, assign(socket, :confirm_delete, confirm)}
    end
  end

  def handle_event("cancel_bulk_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("confirm_bulk_delete", _params, socket) do
    person_ids = MapSet.to_list(socket.assigns.selected_people)

    case people_command(:bulk_delete, %{person_ids: person_ids}) do
      {:ok, %{deleted_count: deleted_count, failed_ids: failed_ids}} ->
        selected_person = socket.assigns.selected_person

        selected_person =
          if selected_person && selected_person.id in person_ids do
            nil
          else
            selected_person
          end

        message =
          if failed_ids == [] do
            "Deleted #{deleted_count} people."
          else
            "Deleted #{deleted_count} people. Failed: #{Enum.join(failed_ids, ", ")}."
          end

        {:noreply,
         socket
         |> assign(:selected_person, selected_person)
         |> assign(
           :person_channels,
           if(selected_person, do: socket.assigns.person_channels, else: [])
         )
         |> assign(:selected_people, MapSet.new())
         |> assign(:confirm_delete, nil)
         |> refresh_people()
         |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Bulk delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("deselect_person", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:person_documents, [])
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
          person = fetch_person!(params["id"])
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
          team = fetch_team!(params["id"])
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
     |> assign(:modal_errors, [])
     |> assign(:merge_survivor, nil)
     |> assign(:merge_loser, nil)
     |> assign(:merge_search, "")
     |> assign(:merge_candidates, [])}
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
        :edit ->
          people_command(:update, %{id: socket.assigns.modal_changeset.data.id, attrs: attrs})

        _ ->
          people_command(:create, %{attrs: attrs})
      end

    case result do
      {:ok, _person} ->
        selected =
          if socket.assigns.selected_person do
            fetch_person_with_channels!(socket.assigns.selected_person.id)
          end

        {:noreply,
         socket
         |> assign(:selected_person, selected)
         |> assign(:person_channels, if(selected, do: selected.channels, else: []))
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])
         |> refresh_people()}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  def handle_event("save", %{"channel" => attrs}, socket) do
    person_id = socket.assigns.modal_parent_id || socket.assigns.selected_person.id

    result =
      case socket.assigns.modal do
        :edit ->
          people_command(:update_channel, %{
            id: socket.assigns.modal_changeset.data.id,
            attrs: attrs
          })

        _ ->
          attrs
          |> Map.put("person_id", person_id)
          |> then(&people_command(:add_channel, %{attrs: &1}))
      end

    case result do
      {:ok, _channel} ->
        person = fetch_person_with_channels!(person_id)

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_channels, person.channels)
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])
         |> refresh_people()}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    result =
      case socket.assigns.modal do
        :edit ->
          people_command(:update_team, %{id: socket.assigns.modal_changeset.data.id, attrs: attrs})

        _ ->
          people_command(:create_team, %{attrs: attrs})
      end

    case result do
      {:ok, _team} ->
        {:noreply,
         socket
         |> refresh_teams()
         |> assign(:modal, nil)
         |> assign(:modal_entity, nil)
         |> assign(:modal_changeset, nil)
         |> assign(:modal_errors, [])
         |> refresh_people()}

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
    case people_command(:delete, %{id: id}) do
      {:ok, _} ->
        deselect =
          socket.assigns.selected_person && to_string(socket.assigns.selected_person.id) == id

        {:noreply,
         socket
         |> assign(:selected_person, if(deselect, do: nil, else: socket.assigns.selected_person))
         |> assign(:person_channels, if(deselect, do: [], else: socket.assigns.person_channels))
         |> assign(:confirm_delete, nil)
         |> refresh_people()}

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

    case people_command(:delete_channel, %{id: channel.id}) do
      {:ok, _} ->
        person = fetch_person_with_channels!(socket.assigns.selected_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_channels, person.channels)
         |> assign(:confirm_delete, nil)
         |> refresh_people()}

      {:error, _} ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event(
        "delete",
        _params,
        %{assigns: %{confirm_delete: %{entity: "team", id: id}}} = socket
      ) do
    case people_command(:delete_team, %{id: id}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_teams()
         |> assign(:confirm_delete, nil)
         |> refresh_people()}

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
      people_command(:swap_channel_weights, %{a_id: current.id, b_id: previous.id})
      person = fetch_person_with_channels!(socket.assigns.selected_person.id)

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
      people_command(:swap_channel_weights, %{a_id: current.id, b_id: next.id})
      person = fetch_person_with_channels!(socket.assigns.selected_person.id)

      {:noreply,
       socket
       |> assign(:selected_person, person)
       |> assign(:person_channels, person.channels)}
    else
      {:noreply, socket}
    end
  end

  # ── Team assignment ───────────────────────────────────────────────────────

  def handle_event("assign_team_select", %{"team_id" => team_id_str}, socket) do
    case Integer.parse(team_id_str) do
      {team_id, ""} -> assign_team_to_selected(socket, team_id)
      # Non-numeric value (e.g. a not-yet-created team name typed in the inline
      # create flow, or a blank selection) — `create_and_assign_team` owns that
      # path, so ignore it here instead of crashing on `String.to_integer/1`.
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_team", %{"team_id" => team_id_str}, socket) do
    team_id = String.to_integer(team_id_str)
    person = socket.assigns.selected_person

    result =
      if team_id in person.team_ids do
        people_command(:unassign_team, %{person_id: person.id, team_id: team_id})
      else
        people_command(:assign_team, %{person_id: person.id, team_id: team_id})
      end

    case result do
      {:ok, updated_person} ->
        person_with_channels = fetch_person_with_channels!(updated_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person_with_channels)
         |> assign(:person_channels, person_with_channels.channels)
         |> refresh_people()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # ── Inline team create (fired by SearchableSelect via pushEvent) ─────────────

  def handle_event("create_and_assign_team", %{"name" => name}, socket) do
    person = socket.assigns.selected_person

    with {:ok, team} <- people_command(:create_team, %{attrs: %{name: name}}),
         {:ok, _} <- people_command(:assign_team, %{person_id: person.id, team_id: team.id}) do
      person_with_channels = fetch_person_with_channels!(person.id)

      {:noreply,
       socket
       |> refresh_teams()
       |> assign(:selected_person, person_with_channels)
       |> assign(:person_channels, person_with_channels.channels)
       |> refresh_people()
       |> put_flash(:info, "Team \"#{name}\" created and assigned.")}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create team.")}
    end
  end

  # ── People filters ────────────────────────────────────────────────────────────

  def handle_event("filter_people", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_name, Map.get(params, "filter_name", ""))
     |> assign(:filter_email, Map.get(params, "filter_email", ""))
     |> assign(:filter_phone, Map.get(params, "filter_phone", ""))
     |> assign(:filter_complete, Map.get(params, "filter_complete", "all"))
     |> assign(:filter_team_id, Map.get(params, "filter_team_id", ""))
     |> assign(:page, 1)
     |> refresh_people()}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, String.to_integer(page))
     |> refresh_people()}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp assign_team_to_selected(socket, team_id) do
    person = socket.assigns.selected_person

    case people_command(:assign_team, %{person_id: person.id, team_id: team_id}) do
      {:ok, updated_person} ->
        person_with_channels = fetch_person_with_channels!(updated_person.id)

        {:noreply,
         socket
         |> assign(:selected_person, person_with_channels)
         |> assign(:person_channels, person_with_channels.channels)
         |> refresh_people()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp refresh_people(socket) do
    filters = %{
      "name" => socket.assigns.filter_name,
      "email" => socket.assigns.filter_email,
      "phone" => socket.assigns.filter_phone,
      "complete" => socket.assigns.filter_complete,
      "team_id" => socket.assigns.filter_team_id
    }

    opts = [page: socket.assigns.page, per_page: socket.assigns.per_page]

    {people, total} =
      case people_command(:filter, %{filters: filters, opts: opts}) do
        {rows, count} when is_list(rows) and is_integer(count) -> {rows, count}
        _ -> {[], 0}
      end

    visible_ids = MapSet.new(Enum.map(people, & &1.id))
    selected_people = MapSet.intersection(socket.assigns.selected_people, visible_ids)

    socket
    |> assign(:people, people)
    |> assign(:selected_people, selected_people)
    |> assign(:total_count, total)
  end

  defp refresh_teams(socket) do
    teams =
      case people_command(:list_teams, %{}) do
        {:ok, teams} when is_list(teams) -> teams
        _ -> []
      end

    assign(socket, :teams, teams)
  end

  defp people_command(op, params) when is_atom(op) and is_map(params) do
    Event.new(%{op: op, params: params}, :engine, opts: [action: :people_command])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp fetch_person_with_channels(id) do
    case people_command(:get_with_channels, %{id: id}) do
      {:ok, person} -> person
      _ -> nil
    end
  end

  defp fetch_person_with_channels!(id) do
    case fetch_person_with_channels(id) do
      nil -> raise Ecto.NoResultsError, queryable: Person
      person -> person
    end
  end

  defp fetch_person!(id) do
    case people_command(:get, %{id: id}) do
      {:ok, person} -> person
      _ -> raise Ecto.NoResultsError, queryable: Person
    end
  end

  defp fetch_team!(id) do
    case people_command(:get_team, %{id: id}) do
      {:ok, team} -> team
      _ -> raise Ecto.NoResultsError, queryable: Team
    end
  end

  defp search_people(query, exclude_ids) do
    case people_command(:search, %{query: query, exclude_ids: exclude_ids, limit: 10}) do
      {:ok, people} when is_list(people) -> people
      _ -> []
    end
  end

  # ── Components ──────────────────────────────────────────────────────────────

  defp delete_confirm_bar(assigns) do
    ~H"""
    <div class="mb-4 rounded-xl bg-red-50 border border-red-200 px-5 py-3 flex items-center justify-between gap-4">
      <p class="font-mono text-sm text-red-700">
        {Map.get(@confirm_delete, :message) ||
          "Are you sure you want to delete this #{@confirm_delete.entity}? This cannot be undone."}
      </p>
      <div class="flex items-center gap-2 flex-shrink-0">
        <button
          phx-click={Map.get(@confirm_delete, :event, "delete")}
          class="font-mono text-[0.75rem] font-bold px-4 py-1.5 rounded-lg bg-red-600 text-white hover:bg-red-700 transition-colors"
        >
          Confirm
        </button>
        <button
          phx-click={Map.get(@confirm_delete, :cancel_event, "cancel_delete")}
          class="font-mono text-[0.75rem] px-4 py-1.5 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
        >
          Cancel
        </button>
      </div>
    </div>
    """
  end

  defp people_tab(assigns) do
    ~H"""
    <div>
      <form
        phx-change="filter_people"
        class="zaq-master-pane-filter-bar"
      >
        <input
          type="text"
          name="filter_name"
          value={@filter_name}
          phx-debounce="300"
          placeholder="Name…"
          class="font-mono text-[0.72rem] text-black px-2.5 py-1.5 rounded-lg border border-black/12 bg-black/[0.02] focus:outline-none focus:ring-1 focus:ring-[var(--zaq-color-accent-border)] min-w-[80px] flex-1"
        />
        <input
          type="text"
          name="filter_email"
          value={@filter_email}
          phx-debounce="300"
          placeholder="Email…"
          class="font-mono text-[0.72rem] text-black px-2.5 py-1.5 rounded-lg border border-black/12 bg-black/[0.02] focus:outline-none focus:ring-1 focus:ring-[var(--zaq-color-accent-border)] min-w-[80px] flex-1"
        />
        <input
          type="text"
          name="filter_phone"
          value={@filter_phone}
          phx-debounce="300"
          placeholder="Phone…"
          class="font-mono text-[0.72rem] text-black px-2.5 py-1.5 rounded-lg border border-black/12 bg-black/[0.02] focus:outline-none focus:ring-1 focus:ring-[var(--zaq-color-accent-border)] min-w-[70px] flex-1"
        />
        <select
          name="filter_complete"
          class="font-mono text-[0.72rem] text-black px-2 py-1.5 rounded-lg border border-black/12 bg-white focus:outline-none focus:ring-1 focus:ring-[var(--zaq-color-accent-border)]"
        >
          <option value="all" selected={@filter_complete == "all"}>All</option>
          <option value="complete" selected={@filter_complete == "complete"}>Complete</option>
          <option value="incomplete" selected={@filter_complete == "incomplete"}>Incomplete</option>
        </select>
        <div class="min-w-[130px]">
          <.searchable_select
            id="filter-team-select"
            name="filter_team_id"
            value={@filter_team_id}
            options={[{"All teams", ""} | Enum.map(@teams, &{&1.name, &1.id})]}
            placeholder="Search teams…"
            empty_label="All teams"
            compact={true}
          />
        </div>
      </form>
      <.table_selection_bar selected_count={MapSet.size(@selected_people)}>
        <:actions>
          <DSButton.button
            id="bulk-delete-button"
            variant={:tertiary}
            danger
            phx-click="open_bulk_delete_modal"
          >
            Delete selected
          </DSButton.button>
        </:actions>
      </.table_selection_bar>
      <EmptyState.empty_state
        :if={@people == []}
        title="No people yet."
        hint={"Click \"New Person\" to add one."}
      />
      <PeopleTable.people_table
        :if={@people != []}
        people={@people}
        selected_people={@selected_people}
        selected_person={@selected_person}
      />
      <SimplePagination.simple_pagination
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
      />
    </div>
    """
  end

  defp teams_tab(assigns) do
    ~H"""
    <div>
      <EmptyState.empty_state
        :if={@teams == []}
        title="No teams yet."
        hint={"Click \"New Team\" to add one."}
      />
      <TeamsTable.teams_table :if={@teams != []} teams={@teams} />
    </div>
    """
  end

  defp person_detail(assigns) do
    ~H"""
    <div class="flex-1 min-w-0">
      <div class="bg-white rounded-xl border border-black/10">
        <%!-- Header --%>
        <div class="flex items-start justify-between px-6 py-5 border-b border-black/8">
          <div class="flex items-center gap-4 min-w-0">
            <div class="w-12 h-12 rounded-xl zaq-bg-ink-soft grid place-items-center flex-shrink-0 font-mono text-lg font-bold zaq-text-ink-soft">
              {String.first(@selected_person.full_name) |> String.upcase()}
            </div>
            <div class="min-w-0">
              <h3 class="font-mono text-base font-bold zaq-text-ink truncate">
                {@selected_person.full_name}
              </h3>
              <p :if={@selected_person.email} class="font-mono text-[0.72rem] text-black/45 mt-0.5">
                {@selected_person.email}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2 flex-shrink-0 ml-4">
            <button
              phx-click="open_modal"
              phx-value-action="edit"
              phx-value-entity="person"
              phx-value-id={@selected_person.id}
              class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
            >
              Edit
            </button>
            <button
              phx-click="open_merge_modal"
              phx-value-id={@selected_person.id}
              class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-[var(--zaq-color-accent)] zaq-text-accent hover:bg-[var(--zaq-color-accent-soft)] transition-colors"
            >
              Merge
            </button>
            <button
              phx-click="confirm_delete"
              phx-value-entity="person"
              phx-value-id={@selected_person.id}
              class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-red-200 text-red-500 hover:bg-red-50 transition-colors"
            >
              Delete
            </button>
            <button
              phx-click="deselect_person"
              class="w-7 h-7 rounded-lg border border-black/15 text-black/40 hover:bg-black/5 flex items-center justify-center transition-colors"
            >
              <svg
                class="w-3.5 h-3.5"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>
        <%!-- Info grid --%>
        <div class="px-6 py-4 grid grid-cols-3 gap-4 border-b border-black/6">
          <div>
            <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">Role</p>
            <p class="font-mono text-[0.78rem] text-black/70">{@selected_person.role || "—"}</p>
          </div>
          <div>
            <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">Status</p>
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class={[
                "font-mono text-[0.72rem] px-2 py-0.5 rounded",
                if(@selected_person.status == "active",
                  do: "bg-emerald-100 text-emerald-700",
                  else: "bg-black/6 text-black/40"
                )
              ]}>
                {@selected_person.status}
              </span>
              <span
                :if={@selected_person.incomplete}
                class="font-mono text-[0.62rem] px-1.5 py-0.5 rounded bg-amber-100 text-amber-600 border border-amber-200"
              >
                incomplete
              </span>
            </div>
          </div>
          <div>
            <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">Email</p>
            <p class="font-mono text-[0.78rem] text-black/70 truncate">
              {@selected_person.email || "—"}
            </p>
          </div>
          <div>
            <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">Phone</p>
            <p class="font-mono text-[0.78rem] text-black/70 truncate">
              {@selected_person.phone || "—"}
            </p>
          </div>
        </div>
        <%!-- Teams section --%>
        <div class="px-6 py-4 border-b border-black/6">
          <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-3">Teams</p>
          <% teams_map = Map.new(@teams, &{&1.id, &1}) %>
          <div class="flex flex-wrap gap-1.5 mb-3">
            <span :if={@selected_person.team_ids == []} class="font-mono text-[0.72rem] text-black/30">
              No teams assigned.
            </span>
            <span
              :for={tid <- @selected_person.team_ids}
              :if={Map.has_key?(teams_map, tid)}
              data-testid={"person-team-badge-#{tid}"}
              class="inline-flex items-center gap-1 font-mono text-[0.68rem] pl-2 pr-1 py-0.5 rounded-full zaq-bg-ink-soft zaq-text-ink-soft border zaq-border-ink-soft"
            >
              {teams_map[tid].name}
              <button
                phx-click="toggle_team"
                phx-value-team_id={tid}
                class="w-3.5 h-3.5 rounded-full flex items-center justify-center zaq-text-ink-soft hover:text-[var(--zaq-color-ink)] hover:bg-black/10 transition-colors"
                title="Remove"
              >
                <svg
                  class="w-2.5 h-2.5"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2.5"
                  viewBox="0 0 24 24"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </span>
          </div>
          <% unassigned_teams = Enum.reject(@teams, &(&1.id in @selected_person.team_ids)) %>
          <form phx-change="assign_team_select">
            <.searchable_select
              id={"team-select-#{@selected_person.id}-#{length(@selected_person.team_ids)}"}
              name="team_id"
              value=""
              options={Enum.map(unassigned_teams, &{&1.name, &1.id})}
              placeholder="Search or create team…"
              empty_label="Assign a team…"
              allow_create={true}
              on_create_event="create_and_assign_team"
            />
          </form>
        </div>
        <%!-- Documents section --%>
        <div class="px-6 py-4 border-b border-black/6">
          <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-3">
            Documents
          </p>
          <div :if={@person_documents == []} class="py-2">
            <p class="font-mono text-[0.72rem] text-black/25">
              No documents shared with this person.
            </p>
          </div>
          <div :if={@person_documents != []} class="max-h-48 overflow-y-auto space-y-1.5 pr-1">
            <div
              :for={perm <- @person_documents}
              class="flex items-center gap-2 px-3 py-2 rounded-lg bg-black/[0.02] border border-black/6"
            >
              <div class="flex-1 min-w-0">
                <p class="font-mono text-[0.75rem] text-black/70 truncate">
                  {perm.document.title || perm.document.source}
                </p>
              </div>
              <div class="flex items-center gap-1 flex-shrink-0">
                <span
                  :for={right <- perm.access_rights}
                  class="font-mono text-[0.6rem] px-1.5 py-0.5 rounded zaq-bg-accent-soft zaq-text-accent border border-[var(--zaq-color-accent)]"
                >
                  {right}
                </span>
              </div>
            </div>
          </div>
        </div>
        <%!-- Channels section --%>
        <div class="px-6 py-4">
          <div class="flex items-center justify-between mb-3">
            <h4 class="font-mono text-[0.72rem] uppercase tracking-wider text-black/35">Channels</h4>
            <button
              id="add-channel-button"
              phx-click="open_modal"
              phx-value-action="new"
              phx-value-entity="channel"
              phx-value-parent_id={@selected_person.id}
              class="font-mono text-[0.68rem] px-2.5 py-1 rounded-lg border border-[var(--zaq-color-accent)] zaq-text-accent hover:bg-[var(--zaq-color-accent-soft)] transition-colors"
            >
              + Add Channel
            </button>
          </div>
          <div :if={@person_channels == []} class="py-6 text-center">
            <p class="font-mono text-[0.72rem] text-black/25">No channels yet.</p>
          </div>
          <div :if={@person_channels != []} class="space-y-2">
            <div
              :for={{channel, idx} <- Enum.with_index(@person_channels)}
              class="flex items-center gap-3 px-3 py-2.5 rounded-lg bg-black/[0.02] border border-black/6"
            >
              <span class="font-mono text-[0.65rem] font-semibold px-2 py-0.5 rounded zaq-bg-ink-soft zaq-text-ink-soft flex-shrink-0">
                {channel.platform}
              </span>
              <div class="flex-1 min-w-0">
                <p class="font-mono text-[0.78rem] text-black/70 truncate">
                  {channel.channel_identifier}
                </p>
                <p
                  :if={channel.display_name || channel.username}
                  class="font-mono text-[0.65rem] text-black/40 truncate"
                >
                  {channel.display_name || channel.username}
                </p>
                <p
                  :if={channel.dm_channel_id}
                  class="font-mono text-[0.62rem] text-black/30 truncate mt-0.5"
                >
                  dm: {channel.dm_channel_id}
                </p>
                <p
                  :if={channel.last_interaction_at}
                  class="font-mono text-[0.62rem] text-black/30 mt-0.5"
                >
                  last seen {Calendar.strftime(channel.last_interaction_at, "%Y-%m-%d %H:%M")}
                </p>
              </div>
              <span
                :if={idx == 0}
                class="font-mono text-[0.62rem] px-1.5 py-0.5 rounded bg-amber-100 text-amber-600 border border-amber-200 flex-shrink-0"
              >
                primary
              </span>
              <div class="flex items-center gap-1 flex-shrink-0">
                <button
                  :if={idx > 0}
                  phx-click="move_channel_up"
                  phx-value-channel_id={channel.id}
                  class="w-6 h-6 rounded flex items-center justify-center text-black/30 hover:text-black/60 hover:bg-black/8 transition-colors"
                  title="Move up"
                >
                  <svg
                    class="w-3 h-3"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.5"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M5 15l7-7 7 7" />
                  </svg>
                </button>
                <button
                  :if={idx < length(@person_channels) - 1}
                  phx-click="move_channel_down"
                  phx-value-channel_id={channel.id}
                  class="w-6 h-6 rounded flex items-center justify-center text-black/30 hover:text-black/60 hover:bg-black/8 transition-colors"
                  title="Move down"
                >
                  <svg
                    class="w-3 h-3"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.5"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
                  </svg>
                </button>
                <button
                  phx-click="open_modal"
                  phx-value-action="edit"
                  phx-value-entity="channel"
                  phx-value-id={channel.id}
                  class="w-6 h-6 rounded flex items-center justify-center text-black/30 hover:text-black/60 hover:bg-black/8 transition-colors"
                  title="Edit"
                >
                  <svg
                    class="w-3 h-3"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <path d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                  </svg>
                </button>
                <button
                  phx-click="confirm_delete"
                  phx-value-entity="channel"
                  phx-value-id={channel.id}
                  class="w-6 h-6 rounded flex items-center justify-center text-red-300 hover:text-red-500 hover:bg-red-50 transition-colors"
                  title="Delete"
                >
                  <svg
                    class="w-3 h-3"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <polyline points="3 6 5 6 21 6" /><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6" /><path d="M10 11v6m4-6v6" /><path d="M9 6V4h6v2" />
                  </svg>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp people_modal(assigns) do
    ~H"""
    <div
      id="people-modal-overlay"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm"
    >
      <div class="bg-white rounded-2xl shadow-2xl border border-black/10 w-full max-w-md mx-4">
        <div class="flex items-center justify-between px-6 py-4 border-b border-black/8">
          <h3 class="font-mono text-sm font-bold zaq-text-ink">
            {case {@modal, @modal_entity} do
              {:new, :person} -> "New Person"
              {:edit, :person} -> "Edit Person"
              {:new, :channel} -> "Add Channel"
              {:edit, :channel} -> "Edit Channel"
              {:new, :team} -> "New Team"
              {:edit, :team} -> "Edit Team"
              {:merge, :merge} -> "Merge Persons"
              _ -> ""
            end}
          </h3>
          <button
            phx-click="close_modal"
            class="w-7 h-7 rounded-lg border border-black/15 text-black/40 hover:bg-black/5 flex items-center justify-center transition-colors"
          >
            <svg
              class="w-3.5 h-3.5"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        <.person_form :if={@modal_entity == :person} modal_changeset={@modal_changeset} />
        <.channel_form :if={@modal_entity == :channel} modal_changeset={@modal_changeset} />
        <.merge_form
          :if={@modal == :merge}
          merge_survivor={@merge_survivor}
          merge_loser={@merge_loser}
          merge_search={@merge_search}
          merge_candidates={@merge_candidates}
        />
        <.team_form :if={@modal_entity == :team} modal_changeset={@modal_changeset} />
      </div>
    </div>
    """
  end

  defp person_form(assigns) do
    ~H"""
    <div class="px-6 py-5">
      <.form
        id="person-modal-form"
        for={@modal_changeset}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Full Name *</label>
          <input
            type="text"
            name="person[full_name]"
            value={Ecto.Changeset.get_field(@modal_changeset, :full_name)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="Jane Smith"
          />
          <p
            :if={@modal_changeset.errors[:full_name]}
            class="font-mono text-[0.68rem] text-red-500 mt-1"
          >
            {translate_error(@modal_changeset.errors[:full_name])}
          </p>
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Email</label>
          <input
            type="email"
            name="person[email]"
            value={Ecto.Changeset.get_field(@modal_changeset, :email)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="jane@example.com"
          />
          <p :if={@modal_changeset.errors[:email]} class="font-mono text-[0.68rem] text-red-500 mt-1">
            {translate_error(@modal_changeset.errors[:email])}
          </p>
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Phone</label>
          <input
            type="tel"
            name="person[phone]"
            value={Ecto.Changeset.get_field(@modal_changeset, :phone)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="+1 555 000 0000"
          />
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Role</label>
          <input
            type="text"
            name="person[role]"
            value={Ecto.Changeset.get_field(@modal_changeset, :role)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="Senior Engineer"
          />
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Status</label>
          <select
            name="person[status]"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
          >
            <option
              value="active"
              selected={Ecto.Changeset.get_field(@modal_changeset, :status) == "active"}
            >
              active
            </option>
            <option
              value="inactive"
              selected={Ecto.Changeset.get_field(@modal_changeset, :status) == "inactive"}
            >
              inactive
            </option>
          </select>
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click="close_modal"
            class="font-mono text-[0.75rem] px-4 py-2 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            id="save-person-button"
            type="submit"
            class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] transition-colors"
          >
            Save
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp channel_form(%{modal_changeset: changeset} = assigns) do
    current = Ecto.Changeset.get_field(changeset, :platform)

    platform_options =
      ~w(mattermost slack microsoft_teams whatsapp telegram discord email)
      |> Enum.map_join(fn p ->
        selected = if current == p, do: ~s( selected="selected"), else: ""
        ~s(<option value="#{p}"#{selected}>#{p}</option>)
      end)
      |> Phoenix.HTML.raw()

    assigns = assign(assigns, :platform_options, platform_options)

    ~H"""
    <div class="px-6 py-5">
      <.form
        id="channel-modal-form"
        for={@modal_changeset}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Platform *</label>
          <select
            name="channel[platform]"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
          >
            <option value="">Select platform…</option>
            {@platform_options}
          </select>
          <p
            :if={@modal_changeset.errors[:platform]}
            class="font-mono text-[0.68rem] text-red-500 mt-1"
          >
            {translate_error(@modal_changeset.errors[:platform])}
          </p>
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">
            Channel Identifier *
          </label>
          <input
            type="text"
            name="channel[channel_identifier]"
            value={Ecto.Changeset.get_field(@modal_changeset, :channel_identifier)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="@jane or jane@example.com"
          />
          <p
            :if={@modal_changeset.errors[:channel_identifier]}
            class="font-mono text-[0.68rem] text-red-500 mt-1"
          >
            {translate_error(@modal_changeset.errors[:channel_identifier])}
          </p>
        </div>
        <div :if={Ecto.Changeset.get_field(@modal_changeset, :platform) == "mattermost"}>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">DM Channel ID</label>
          <input
            type="text"
            name="channel[dm_channel_id]"
            value={Ecto.Changeset.get_field(@modal_changeset, :dm_channel_id)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="Mattermost DM channel ID"
          />
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click="close_modal"
            class="font-mono text-[0.75rem] px-4 py-2 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            id="save-channel-button"
            type="submit"
            class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] transition-colors"
          >
            Save
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp merge_form(assigns) do
    ~H"""
    <div class="px-6 py-5 space-y-4">
      <%!-- Survivor row --%>
      <div>
        <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">
          Survivor (kept)
        </p>
        <div
          :if={@merge_survivor}
          class="flex items-center gap-2 px-3 py-2 rounded-lg bg-emerald-50 border border-emerald-200"
        >
          <div class="w-7 h-7 rounded bg-emerald-100 grid place-items-center font-mono text-xs font-bold text-emerald-700 flex-shrink-0">
            {String.first(@merge_survivor.full_name) |> String.upcase()}
          </div>
          <div class="min-w-0 flex-1">
            <p class="font-mono text-[0.78rem] font-semibold text-emerald-800 truncate">
              {@merge_survivor.full_name}
            </p>
            <p :if={@merge_survivor.email} class="font-mono text-[0.65rem] text-emerald-600 truncate">
              {@merge_survivor.email}
            </p>
          </div>
          <button
            :if={@merge_loser == nil}
            phx-click="select_merge_survivor"
            phx-value-id=""
            class="font-mono text-[0.62rem] text-emerald-500 hover:text-emerald-700 transition-colors"
          >
            change
          </button>
        </div>
        <div :if={@merge_survivor == nil}>
          <form phx-change="merge_search">
            <input
              type="text"
              name="merge_search"
              value={@merge_search}
              class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
              placeholder="Search person to keep…"
              autocomplete="off"
            />
          </form>
          <div
            :if={@merge_candidates != []}
            class="mt-1 rounded-lg border border-black/10 overflow-hidden divide-y divide-black/6"
          >
            <button
              :for={candidate <- @merge_candidates}
              phx-click="select_merge_survivor"
              phx-value-id={candidate.id}
              class="w-full flex items-center gap-2 px-3 py-2.5 hover:bg-black/[0.03] text-left transition-colors"
            >
              <div class="w-6 h-6 rounded zaq-bg-ink-soft grid place-items-center font-mono text-xs font-bold zaq-text-ink-soft flex-shrink-0">
                {String.first(candidate.full_name) |> String.upcase()}
              </div>
              <div class="min-w-0">
                <p class="font-mono text-[0.75rem] font-semibold zaq-text-ink truncate">
                  {candidate.full_name}
                </p>
                <p :if={candidate.email} class="font-mono text-[0.65rem] text-black/40 truncate">
                  {candidate.email}
                </p>
              </div>
            </button>
          </div>
        </div>
      </div>
      <%!-- Loser row --%>
      <div>
        <p class="font-mono text-[0.62rem] text-black/35 uppercase tracking-wider mb-1">
          Delete (loser — channels moved to survivor)
        </p>
        <div
          :if={@merge_loser}
          class="flex items-center gap-2 px-3 py-2 rounded-lg bg-red-50 border border-red-200"
        >
          <div class="w-7 h-7 rounded bg-red-100 grid place-items-center font-mono text-xs font-bold text-red-700 flex-shrink-0">
            {String.first(@merge_loser.full_name) |> String.upcase()}
          </div>
          <div class="min-w-0 flex-1">
            <p class="font-mono text-[0.78rem] font-semibold text-red-800 truncate">
              {@merge_loser.full_name}
            </p>
            <p :if={@merge_loser.email} class="font-mono text-[0.65rem] text-red-600 truncate">
              {@merge_loser.email}
            </p>
          </div>
          <button
            :if={@merge_survivor == nil}
            phx-click="select_merge_loser"
            phx-value-id=""
            class="font-mono text-[0.62rem] text-red-400 hover:text-red-600 transition-colors"
          >
            change
          </button>
        </div>
        <div :if={@merge_loser == nil}>
          <form phx-change="merge_search">
            <input
              type="text"
              name="merge_search"
              value={@merge_search}
              class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
              placeholder="Search person to delete…"
              autocomplete="off"
            />
          </form>
          <div
            :if={@merge_candidates != []}
            class="mt-1 rounded-lg border border-black/10 overflow-hidden divide-y divide-black/6"
          >
            <button
              :for={candidate <- @merge_candidates}
              phx-click="select_merge_loser"
              phx-value-id={candidate.id}
              class="w-full flex items-center gap-2 px-3 py-2.5 hover:bg-black/[0.03] text-left transition-colors"
            >
              <div class="w-6 h-6 rounded zaq-bg-ink-soft grid place-items-center font-mono text-xs font-bold zaq-text-ink-soft flex-shrink-0">
                {String.first(candidate.full_name) |> String.upcase()}
              </div>
              <div class="min-w-0">
                <p class="font-mono text-[0.75rem] font-semibold zaq-text-ink truncate">
                  {candidate.full_name}
                </p>
                <p :if={candidate.email} class="font-mono text-[0.65rem] text-black/40 truncate">
                  {candidate.email}
                </p>
              </div>
            </button>
          </div>
        </div>
      </div>
      <%!-- Preview --%>
      <div
        :if={@merge_survivor && @merge_loser}
        class="px-3 py-2.5 rounded-lg bg-black/[0.02] border border-black/8"
      >
        <p class="font-mono text-[0.65rem] text-black/50">
          {length(@merge_loser.channels)} channel(s) from
          <span class="font-semibold text-black/70">{@merge_loser.full_name}</span>
          will move to <span class="font-semibold text-black/70">{@merge_survivor.full_name}</span>.
          Any missing name/email/phone will be copied. The duplicate will be permanently deleted.
        </p>
      </div>
      <div class="flex justify-end gap-2 pt-1">
        <button
          type="button"
          phx-click="close_modal"
          class="font-mono text-[0.75rem] px-4 py-2 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
        >
          Cancel
        </button>
        <button
          :if={@merge_survivor && @merge_loser}
          phx-click="confirm_merge"
          class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-red-500 text-white hover:bg-red-600 transition-colors"
        >
          Confirm Merge
        </button>
      </div>
    </div>
    """
  end

  defp team_form(assigns) do
    ~H"""
    <div class="px-6 py-5">
      <.form
        id="team-modal-form"
        for={@modal_changeset}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Name *</label>
          <input
            type="text"
            name="team[name]"
            value={Ecto.Changeset.get_field(@modal_changeset, :name)}
            phx-debounce="300"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)]"
            placeholder="Engineering"
          />
          <p :if={@modal_changeset.errors[:name]} class="font-mono text-[0.68rem] text-red-500 mt-1">
            {translate_error(@modal_changeset.errors[:name])}
          </p>
        </div>
        <div>
          <label class="block font-mono text-[0.7rem] text-black/50 mb-1.5">Description</label>
          <textarea
            name="team[description]"
            phx-debounce="300"
            rows="3"
            class="w-full font-mono text-black text-sm px-3 py-2 rounded-lg border border-black/15 bg-black/[0.02] focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent-border)] resize-none"
            placeholder="Optional description…"
          >{Ecto.Changeset.get_field(@modal_changeset, :description)}</textarea>
        </div>
        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click="close_modal"
            class="font-mono text-[0.75rem] px-4 py-2 rounded-lg border border-black/15 text-black/60 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            id="save-team-button"
            type="submit"
            class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] transition-colors"
          >
            Save
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
