defmodule ZaqWeb.Live.BO.AI.OntologyLive do
  @moduledoc """
  BackOffice LiveView for the Ontology feature.

  Displays organizational structure data loaded via the ontology license.
  Gated behind license check — shows "Feature not licensed" if ontology
  feature is not loaded.

  IMPORTANT: All LicenseManager.Paid.Ontology.* modules are injected at runtime
  by LicensePostLoader. They do NOT exist at compile time. Every call must use
  apply/3 or go through context module attributes — never reference structs
  directly (no %Module{} literals, no Module.function() in function heads).

  Has 3 tabs:
  - Org Structure: Businesses → Divisions → Departments → Teams (full CRUD)
  - People & Channels: People with preferred channels and team memberships (full CRUD)
  - Knowledge Domains: Knowledge domains with linked departments (full CRUD)
  """
  # Ontology modules are injected at runtime by LicensePostLoader and do not
  # exist at compile time. apply/3 is the only safe way to call them.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  use ZaqWeb, :live_view

  alias Zaq.License.FeatureStore

  # ---------------------------------------------------------------------------
  # Ontology context modules — stored as atoms, called via apply/3 at runtime.
  # NEVER call these at compile time or use their structs with %Module{}.
  # ---------------------------------------------------------------------------
  @ctx_businesses LicenseManager.Paid.Ontology.Businesses
  @ctx_divisions LicenseManager.Paid.Ontology.Divisions
  @ctx_departments LicenseManager.Paid.Ontology.Departments
  @ctx_teams LicenseManager.Paid.Ontology.Teams
  @ctx_people LicenseManager.Paid.Ontology.People
  @ctx_knowledge_domains LicenseManager.Paid.Ontology.KnowledgeDomains

  # Schema modules — used only via apply/3 for changeset building
  @schema_business LicenseManager.Paid.Ontology.Business
  @schema_division LicenseManager.Paid.Ontology.Division
  @schema_department LicenseManager.Paid.Ontology.Department
  @schema_team LicenseManager.Paid.Ontology.Team
  @schema_person LicenseManager.Paid.Ontology.Person
  @schema_channel LicenseManager.Paid.Ontology.Channel
  @schema_team_member LicenseManager.Paid.Ontology.TeamMember
  @schema_knowledge_domain LicenseManager.Paid.Ontology.KnowledgeDomain

  @tabs [:tree_view, :org_structure, :people, :knowledge_domains]

  @default_contexts %{
    businesses: @ctx_businesses,
    divisions: @ctx_divisions,
    departments: @ctx_departments,
    teams: @ctx_teams,
    people: @ctx_people,
    knowledge_domains: @ctx_knowledge_domains
  }

  @default_schemas %{
    business: @schema_business,
    division: @schema_division,
    department: @schema_department,
    team: @schema_team,
    person: @schema_person,
    channel: @schema_channel,
    team_member: @schema_team_member,
    knowledge_domain: @schema_knowledge_domain
  }

  # Ontology facade module — for full tree queries
  @pubsub_topic "license:updated"

  # =============================================================================
  # Mount & Lifecycle
  # =============================================================================

  @impl true
  def mount(_params, _session, socket) do
    licensed = FeatureStore.feature_loaded?("ontology")

    socket =
      socket
      |> assign(:current_path, "/bo/ontology")
      |> assign(:licensed, licensed)
      |> assign(:active_tab, :tree_view)
      |> assign(:loading, true)
      |> assign(:error, nil)
      # Data assigns
      |> assign(:businesses, [])
      |> assign(:tree_businesses, [])
      |> assign(:tree_data, [])
      |> assign(:people, [])
      |> assign(:domains, [])
      # Modal state
      |> assign(:modal, nil)
      |> assign(:modal_entity, nil)
      |> assign(:modal_changeset, nil)
      |> assign(:modal_parent_id, nil)
      |> assign(:modal_errors, [])
      # Expanded tree nodes (org structure)
      |> assign(:expanded, MapSet.new())
      # People tab — selected person for detail view
      |> assign(:selected_person, nil)
      |> assign(:person_channels, [])
      |> assign(:person_teams, [])
      # Dropdown data for forms
      |> assign(:all_businesses, [])
      |> assign(:all_divisions, [])
      |> assign(:all_departments, [])
      |> assign(:all_teams, [])
      |> assign(:all_people, [])
      # Delete confirmation
      |> assign(:confirm_delete, nil)

    if licensed do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Zaq.PubSub, @pubsub_topic)
      end

      {:ok, load_tab_data(socket, :tree_view)}
    else
      {:ok, assign(socket, :loading, false)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # =============================================================================
  # Tab Switching
  # =============================================================================

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)

    if tab in @tabs do
      {:noreply,
       socket
       |> assign(:modal, nil)
       |> assign(:confirm_delete, nil)
       |> assign(:selected_person, nil)
       |> load_tab_data(tab)}
    else
      {:noreply, socket}
    end
  end

  # =============================================================================
  # Tree Expand/Collapse (Org Structure)
  # =============================================================================

  def handle_event("toggle_node", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # =============================================================================
  # Modal Open / Close
  # =============================================================================

  def handle_event("open_modal", %{"action" => action, "entity" => entity} = params, socket) do
    action = String.to_existing_atom(action)
    entity = String.to_existing_atom(entity)
    parent_id = params["parent_id"]
    record_id = params["id"]

    socket =
      socket
      |> assign(:modal, action)
      |> assign(:modal_entity, entity)
      |> assign(:modal_parent_id, parent_id)
      |> assign(:modal_errors, [])
      |> prepare_modal_changeset(action, entity, record_id, parent_id)

    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, nil)
     |> assign(:modal_entity, nil)
     |> assign(:modal_changeset, nil)
     |> assign(:modal_parent_id, nil)
     |> assign(:modal_errors, [])}
  end

  # =============================================================================
  # Form Validation (live phx-change)
  # =============================================================================

  def handle_event("validate", %{"form" => form_params}, socket) do
    changeset =
      build_changeset(
        socket.assigns.modal_entity,
        socket.assigns.modal_changeset.data,
        form_params
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :modal_changeset, changeset)}
  end

  # =============================================================================
  # Form Submit — Create / Update
  # =============================================================================

  def handle_event("save", %{"form" => form_params}, socket) do
    %{modal: action, modal_entity: entity, modal_parent_id: parent_id} = socket.assigns

    result =
      case action do
        :new -> do_create(entity, form_params, parent_id)
        :edit -> do_update(entity, socket.assigns.modal_changeset.data, form_params)
      end

    case result do
      {:ok, _record} ->
        socket =
          socket
          |> assign(:modal, nil)
          |> assign(:modal_entity, nil)
          |> assign(:modal_changeset, nil)
          |> assign(:modal_errors, [])
          |> put_flash(:info, "#{humanize_entity(entity)} saved successfully.")

        # After adding a team member, refresh the selected person's teams
        socket =
          if entity == :team_member and socket.assigns.selected_person do
            person_id = socket.assigns.selected_person.id
            person = apply(ctx(:people), :get_with_channels, [person_id])
            teams = person |> repo().preload(:teams) |> Map.get(:teams, [])

            socket
            |> assign(:selected_person, person)
            |> assign(:person_teams, teams)
          else
            socket
          end

        {:noreply, reload_current_tab(socket)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:modal_changeset, changeset)
         |> assign(:modal_errors, format_changeset_errors(changeset))}
    end
  end

  # =============================================================================
  # Delete Confirmation Flow
  # =============================================================================

  def handle_event("confirm_delete", %{"entity" => entity, "id" => id}, socket) do
    {:noreply,
     assign(socket, :confirm_delete, %{entity: String.to_existing_atom(entity), id: id})}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("delete", _params, socket) do
    %{entity: entity, id: id} = socket.assigns.confirm_delete

    case do_delete(entity, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:info, "#{humanize_entity(entity)} deleted.")
         |> reload_current_tab()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(
           :error,
           "Delete failed: #{format_changeset_errors(changeset) |> Enum.join(", ")}"
         )}
    end
  end

  # =============================================================================
  # People Tab — Select Person / Channel / Membership Management
  # =============================================================================

  def handle_event("select_person", %{"id" => id}, socket) do
    person = apply(ctx(:people), :get_with_channels, [id])
    channels = apply(ctx(:people), :list_channels, [id])

    teams =
      person
      |> repo().preload(:teams)
      |> Map.get(:teams, [])

    {:noreply,
     socket
     |> assign(:selected_person, person)
     |> assign(:person_channels, channels)
     |> assign(:person_teams, teams)}
  end

  def handle_event("deselect_person", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_person, nil)
     |> assign(:person_channels, [])
     |> assign(:person_teams, [])}
  end

  def handle_event(
        "set_preferred_channel",
        %{"person_id" => person_id, "channel_id" => channel_id},
        socket
      ) do
    person = apply(ctx(:people), :get, [person_id])

    case apply(ctx(:people), :set_preferred_channel, [person, channel_id]) do
      {:ok, updated_person} ->
        {:noreply,
         socket
         |> assign(:selected_person, apply(ctx(:people), :get_with_channels, [updated_person.id]))
         |> put_flash(:info, "Preferred channel updated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update preferred channel.")}
    end
  end

  # Team membership from People tab
  def handle_event(
        "add_team_member",
        %{"form" => %{"team_id" => team_id, "person_id" => person_id} = params},
        socket
      ) do
    attrs = %{
      team_id: team_id,
      person_id: person_id,
      role_in_team: params["role_in_team"] || nil
    }

    case apply(ctx(:teams), :add_member, [attrs]) do
      {:ok, _member} ->
        person = apply(ctx(:people), :get_with_channels, [person_id])
        teams = person |> repo().preload(:teams) |> Map.get(:teams, [])

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_teams, teams)
         |> assign(:modal, nil)
         |> put_flash(:info, "Team membership added.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to add team membership. May already exist.")}
    end
  end

  def handle_event(
        "remove_team_member",
        %{"team_id" => team_id, "person_id" => person_id},
        socket
      ) do
    case apply(ctx(:teams), :remove_member, [team_id, person_id]) do
      {:ok, _} ->
        person = apply(ctx(:people), :get_with_channels, [person_id])
        teams = person |> repo().preload(:teams) |> Map.get(:teams, [])

        {:noreply,
         socket
         |> assign(:selected_person, person)
         |> assign(:person_teams, teams)
         |> put_flash(:info, "Removed from team.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove team membership.")}
    end
  end

  # =============================================================================
  # PubSub — License Updates
  # =============================================================================

  @impl true
  def handle_info(:license_updated, socket) do
    licensed = FeatureStore.feature_loaded?("ontology")
    socket = assign(socket, :licensed, licensed)

    if licensed do
      {:noreply, load_tab_data(socket, socket.assigns.active_tab)}
    else
      {:noreply, assign(socket, :loading, false)}
    end
  end

  # =============================================================================
  # Async Handlers
  # =============================================================================

  @impl true
  def handle_async(:load_tree_view, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:tree_businesses, result.tree_businesses)
     |> assign(:tree_data, result.tree_data)
     |> assign(:error, result.error)
     |> assign(:loading, false)}
  end

  def handle_async(:load_org_structure, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:businesses, result.businesses)
     |> assign(:error, result.error)
     |> assign(:loading, false)}
  end

  def handle_async(:load_people, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:people, result.people)
     |> assign(:error, result.error)
     |> assign(:loading, false)}
  end

  def handle_async(:load_domains, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:domains, result.domains)
     |> assign(:all_departments, result.all_departments)
     |> assign(:error, result.error)
     |> assign(:loading, false)}
  end

  def handle_async(_task, {:exit, reason}, socket) do
    require Logger
    Logger.error("[OntologyLive] Async task failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:error, "An unexpected error occurred while loading data.")}
  end

  # =============================================================================
  # Data Loading (Async)
  # =============================================================================

  defp load_tab_data(socket, :tree_view) do
    socket
    |> assign(:active_tab, :tree_view)
    |> assign(:loading, true)
    |> assign(:error, nil)
    |> start_async(:load_tree_view, fn ->
      try do
        # Full tree: Business → Divisions → Departments → (Teams → Members → Person, KnowledgeDomains)
        tree_businesses =
          apply(ctx(:businesses), :list, [])
          |> repo().preload(
            divisions: [
              departments: [
                :knowledge_domains,
                teams: [team_members: :person]
              ]
            ]
          )

        # Serialize to the JSON structure the JS hook expects
        tree_data = Enum.map(tree_businesses, &serialize_business/1)

        %{tree_businesses: tree_businesses, tree_data: tree_data, error: nil}
      rescue
        e ->
          require Logger
          Logger.error("[OntologyLive] Failed to load tree view: #{Exception.message(e)}")

          %{
            tree_businesses: [],
            tree_data: [],
            error: "Failed to load tree data. Migrations may still be running."
          }
      end
    end)
  end

  defp load_tab_data(socket, :org_structure) do
    socket
    |> assign(:active_tab, :org_structure)
    |> assign(:loading, true)
    |> assign(:error, nil)
    |> start_async(:load_org_structure, fn ->
      try do
        businesses =
          apply(ctx(:businesses), :list, [])
          |> repo().preload(divisions: [departments: :teams])

        %{businesses: businesses, error: nil}
      rescue
        e ->
          require Logger
          Logger.error("[OntologyLive] Failed to load org structure: #{Exception.message(e)}")

          %{
            businesses: [],
            error: "Failed to load organization data. Migrations may still be running."
          }
      end
    end)
  end

  defp load_tab_data(socket, :people) do
    socket
    |> assign(:active_tab, :people)
    |> assign(:loading, true)
    |> assign(:error, nil)
    |> assign(:selected_person, nil)
    |> start_async(:load_people, fn ->
      try do
        people =
          apply(ctx(:people), :list_active, [])
          |> repo().preload([:teams, :preferred_channel])

        %{people: people, error: nil}
      rescue
        e ->
          require Logger
          Logger.error("[OntologyLive] Failed to load people: #{Exception.message(e)}")
          %{people: [], error: "Failed to load people data. Migrations may still be running."}
      end
    end)
  end

  defp load_tab_data(socket, :knowledge_domains) do
    socket
    |> assign(:active_tab, :knowledge_domains)
    |> assign(:loading, true)
    |> assign(:error, nil)
    |> start_async(:load_domains, fn ->
      try do
        business = apply(ctx(:businesses), :get_by_slug, ["default"])

        domains =
          apply(ctx(:knowledge_domains), :list_by_business, [business.id])
          |> repo().preload(department: [division: :business])

        # Load all departments for the "new domain" form dropdown
        all_departments =
          business
          |> repo().preload(divisions: :departments)
          |> Map.get(:divisions, [])
          |> Enum.flat_map(fn div ->
            Enum.map(div.departments, fn dept ->
              %{id: dept.id, name: dept.name, division_name: div.name}
            end)
          end)

        %{domains: domains, all_departments: all_departments, error: nil}
      rescue
        e ->
          require Logger
          Logger.error("[OntologyLive] Failed to load knowledge domains: #{Exception.message(e)}")

          %{
            domains: [],
            all_departments: [],
            error: "Failed to load knowledge domain data. Migrations may still be running."
          }
      end
    end)
  end

  # =============================================================================
  # Private — Modal Changeset Preparation
  # =============================================================================

  defp prepare_modal_changeset(socket, :new, :team_member, _record_id, parent_id) do
    # team_member is special: parent_id is the person_id, we need a team dropdown
    schema_mod = schema(:team_member)
    empty_struct = apply(schema_mod, :__struct__, [])
    changeset = apply(schema_mod, :changeset, [empty_struct, %{"person_id" => parent_id}])

    socket
    |> assign(:modal_changeset, changeset)
    |> assign(:modal_parent_id, parent_id)
    |> maybe_load_dropdown_data(:team_member)
  end

  defp prepare_modal_changeset(socket, :new, entity, _record_id, parent_id) do
    default_attrs = new_default_attrs(entity, parent_id)
    schema_mod = schema_module_for(entity)
    # Build struct at runtime via apply/3 — no compile-time %Module{} expansion
    empty_struct = apply(schema_mod, :__struct__, [])
    changeset = apply(schema_mod, :changeset, [empty_struct, default_attrs])

    socket
    |> assign(:modal_changeset, changeset)
    |> maybe_load_dropdown_data(entity)
  end

  defp prepare_modal_changeset(socket, :edit, entity, record_id, _parent_id) do
    record = get_record(entity, record_id)
    schema_mod = schema_module_for(entity)
    changeset = apply(schema_mod, :changeset, [record, %{}])

    socket
    |> assign(:modal_changeset, changeset)
    |> maybe_load_dropdown_data(entity)
  end

  # =============================================================================
  # Private — Default Attrs for New Records
  # =============================================================================

  defp new_default_attrs(:business, _parent_id), do: %{}
  defp new_default_attrs(:division, parent_id), do: %{"business_id" => parent_id}
  defp new_default_attrs(:department, parent_id), do: %{"division_id" => parent_id}
  defp new_default_attrs(:team, parent_id), do: %{"department_id" => parent_id}
  defp new_default_attrs(:person, _parent_id), do: %{"status" => "active"}
  defp new_default_attrs(:channel, parent_id), do: %{"person_id" => parent_id}
  defp new_default_attrs(:knowledge_domain, parent_id), do: %{"department_id" => parent_id}

  # =============================================================================
  # Private — Schema Module Lookup (atoms only — resolved at runtime)
  # =============================================================================

  defp schema_module_for(entity), do: schema(entity)

  # =============================================================================
  # Private — Changeset Builder (runtime via apply/3)
  # =============================================================================

  defp build_changeset(entity, data, attrs) do
    schema_mod = schema_module_for(entity)
    attrs = normalize_params(entity, attrs)
    apply(schema_mod, :changeset, [data, attrs])
  end

  # =============================================================================
  # Private — CRUD Operations (runtime via apply/3)
  # =============================================================================

  defp do_create(:business, params, _parent_id) do
    apply(ctx(:businesses), :create, [params])
  end

  defp do_create(:division, params, parent_id) do
    apply(ctx(:divisions), :create, [Map.put(params, "business_id", parent_id)])
  end

  defp do_create(:department, params, parent_id) do
    apply(ctx(:departments), :create, [Map.put(params, "division_id", parent_id)])
  end

  defp do_create(:team, params, parent_id) do
    apply(ctx(:teams), :create, [Map.put(params, "department_id", parent_id)])
  end

  defp do_create(:person, params, _parent_id) do
    apply(ctx(:people), :create, [params])
  end

  defp do_create(:channel, params, parent_id) do
    apply(ctx(:people), :add_channel, [Map.put(params, "person_id", parent_id)])
  end

  defp do_create(:team_member, params, _parent_id) do
    attrs = %{
      team_id: params["team_id"],
      person_id: params["person_id"],
      role_in_team: params["role_in_team"]
    }

    apply(ctx(:teams), :add_member, [attrs])
  end

  defp do_create(:knowledge_domain, params, _parent_id) do
    apply(ctx(:knowledge_domains), :create, [normalize_params(:knowledge_domain, params)])
  end

  defp do_update(entity, record, params) do
    ctx_mod = context_module_for(entity)
    fun = update_fun_for(entity)
    apply(ctx_mod, fun, [record, normalize_params(entity, params)])
  end

  defp do_delete(entity, id) do
    record = get_record(entity, id)

    if is_nil(record) do
      {:error, :not_found}
    else
      ctx_mod = context_module_for(entity)
      fun = delete_fun_for(entity)
      apply(ctx_mod, fun, [record])
    end
  end

  # Channel doesn't have its own context get/1 — use Repo directly with
  # runtime module resolution to avoid compile-time struct expansion.
  defp get_record(:channel, id) do
    repo().get(schema_module_for(:channel), id)
  end

  defp get_record(entity, id) do
    apply(context_module_for(entity), :get, [id])
  end

  # =============================================================================
  # Private — Context Module Lookup
  # =============================================================================

  defp context_module_for(:business), do: ctx(:businesses)
  defp context_module_for(:division), do: ctx(:divisions)
  defp context_module_for(:department), do: ctx(:departments)
  defp context_module_for(:team), do: ctx(:teams)
  defp context_module_for(:person), do: ctx(:people)
  defp context_module_for(:channel), do: ctx(:people)
  defp context_module_for(:knowledge_domain), do: ctx(:knowledge_domains)

  defp update_fun_for(:channel), do: :update_channel
  defp update_fun_for(_entity), do: :update

  defp delete_fun_for(:channel), do: :delete_channel
  defp delete_fun_for(_entity), do: :delete

  # =============================================================================
  # Private — Dropdown Data for Forms
  # =============================================================================

  defp maybe_load_dropdown_data(socket, :knowledge_domain) do
    # all_departments already loaded in load_tab_data for knowledge_domains tab
    socket
  end

  defp maybe_load_dropdown_data(socket, :team_member) do
    all_teams =
      apply(ctx(:businesses), :list, [])
      |> repo().preload(divisions: [departments: :teams])
      |> Enum.flat_map(&extract_teams_from_business/1)

    assign(socket, :all_teams, all_teams)
  rescue
    _ -> socket
  end

  defp maybe_load_dropdown_data(socket, _entity), do: socket

  defp extract_teams_from_business(business) do
    Enum.flat_map(business.divisions, &extract_teams_from_division/1)
  end

  defp extract_teams_from_division(division) do
    Enum.flat_map(division.departments, &extract_teams_from_department/1)
  end

  defp extract_teams_from_department(dept) do
    Enum.map(dept.teams, fn t ->
      %{id: t.id, name: t.name, department_name: dept.name}
    end)
  end

  # =============================================================================
  # Private — Helpers
  # =============================================================================

  defp ontology_live_config do
    Application.get_env(:zaq, __MODULE__, [])
  end

  defp repo do
    Keyword.get(ontology_live_config(), :repo, Zaq.Repo)
  end

  defp ctx(key) do
    configured_contexts = ontology_live_config() |> Keyword.get(:contexts, %{})
    Map.get(configured_contexts, key, Map.fetch!(@default_contexts, key))
  end

  defp schema(key) do
    configured_schemas = ontology_live_config() |> Keyword.get(:schemas, %{})
    Map.get(configured_schemas, key, Map.fetch!(@default_schemas, key))
  end

  defp reload_current_tab(socket) do
    load_tab_data(socket, socket.assigns.active_tab)
  end

  # Converts comma-separated keywords string to a list of trimmed strings.
  # The KnowledgeDomain schema expects {:array, :string} but the form sends
  # a raw string like "billing, invoices, payments".
  defp normalize_params(:knowledge_domain, params) when is_map(params) do
    case Map.get(params, "keywords") do
      nil ->
        params

      keywords when is_binary(keywords) ->
        parsed =
          keywords
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "keywords", parsed)

      _already_list ->
        params
    end
  end

  defp normalize_params(_entity, params), do: params

  defp humanize_entity(:business), do: "Business"
  defp humanize_entity(:division), do: "Division"
  defp humanize_entity(:department), do: "Department"
  defp humanize_entity(:team), do: "Team"
  defp humanize_entity(:person), do: "Person"
  defp humanize_entity(:channel), do: "Channel"
  defp humanize_entity(:team_member), do: "Team Membership"
  defp humanize_entity(:knowledge_domain), do: "Knowledge Domain"
  defp humanize_entity(_), do: "Record"

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, &"#{Phoenix.Naming.humanize(field)} #{&1}")
    end)
  end

  defp format_changeset_errors(_), do: []

  # =============================================================================
  # Private — Tree Data Serialization (for JS hook)
  # =============================================================================

  defp serialize_business(business) do
    %{
      name: business.name,
      type: "business",
      children: Enum.map(business.divisions, &serialize_division/1)
    }
  end

  defp serialize_division(division) do
    %{
      name: division.name,
      type: "division",
      children: Enum.map(division.departments, &serialize_department/1)
    }
  end

  defp serialize_department(dept) do
    team_nodes = Enum.map(dept.teams, &serialize_team/1)
    domain_nodes = Enum.map(dept.knowledge_domains, &serialize_knowledge_domain_node/1)

    %{
      name: dept.name,
      type: "department",
      children: team_nodes ++ domain_nodes
    }
  end

  defp serialize_team(team) do
    %{
      name: team.name,
      type: "team",
      children: Enum.map(team.team_members, &serialize_person/1)
    }
  end

  defp serialize_person(tm) do
    %{
      name: tm.person.full_name,
      type: "person",
      role: tm.role_in_team || tm.person.role,
      status: tm.person.status,
      children: []
    }
  end

  defp serialize_knowledge_domain_node(kd) do
    %{
      name: kd.name,
      type: "domain",
      description: kd.description,
      keywords: kd.keywords || [],
      children: []
    }
  end
end
