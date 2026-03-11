defmodule Zaq.TestSupport.OntologyFake.Repo do
  alias LicenseManager.Paid.Ontology.Channel

  def preload(data, _preloads), do: data

  def get(Channel, id) do
    %{
      __struct__: Channel,
      id: id,
      person_id: "person-1",
      platform: "slack",
      channel_identifier: "@fake"
    }
  end

  def get(_schema, id), do: %{id: id}
end

defmodule LicenseManager.Paid.Ontology.Business do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :slug, :string
    field :divisions, {:array, :map}, default: []
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
  end
end

defmodule LicenseManager.Paid.Ontology.Division do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :business_id, :string
    field :departments, {:array, :map}, default: []
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :business_id])
    |> validate_required([:name])
  end
end

defmodule LicenseManager.Paid.Ontology.Department do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :division_id, :string
    field :teams, {:array, :map}, default: []
    field :knowledge_domains, {:array, :map}, default: []
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :division_id])
    |> validate_required([:name])
  end
end

defmodule LicenseManager.Paid.Ontology.Team do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :department_id, :string
    field :team_members, {:array, :map}, default: []
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :department_id])
    |> validate_required([:name])
  end
end

defmodule LicenseManager.Paid.Ontology.Person do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :full_name, :string
    field :email, :string
    field :role, :string
    field :status, :string, default: "active"
    field :preferred_channel_id, :string
    field :preferred_channel, :map
    field :teams, {:array, :map}, default: []
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:full_name, :email, :role, :status, :preferred_channel_id])
    |> validate_required([:full_name])
  end
end

defmodule LicenseManager.Paid.Ontology.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :person_id, :string
    field :platform, :string
    field :channel_identifier, :string
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:person_id, :platform, :channel_identifier])
    |> validate_required([:platform])
  end
end

defmodule LicenseManager.Paid.Ontology.TeamMember do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :team_id, :string
    field :person_id, :string
    field :role_in_team, :string
    field :person, :map
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:team_id, :person_id, :role_in_team])
    |> validate_required([:team_id, :person_id])
  end
end

defmodule LicenseManager.Paid.Ontology.KnowledgeDomain do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :description, :string
    field :keywords, {:array, :string}, default: []
    field :department_id, :string
    field :department, :map
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :description, :keywords, :department_id])
    |> validate_required([:name])
  end
end

defmodule LicenseManager.Paid.Ontology.Businesses do
  alias LicenseManager.Paid.Ontology.Business

  def list, do: [business_tree()]

  def get(id),
    do: %Business{id: id, name: "Business #{id}", slug: "business-#{id}", divisions: []}

  def get_by_slug("default"), do: business_tree()

  def create(params) do
    cs = Business.changeset(%Business{}, params)

    if cs.valid? do
      {:ok,
       %Business{id: "biz-new", name: Map.get(params, "name"), slug: Map.get(params, "slug")}}
    else
      {:error, cs}
    end
  end

  def update(record, params) do
    {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}
  end

  def delete(%{id: "err-delete"}) do
    {:error,
     Ecto.Changeset.add_error(Ecto.Changeset.change(%Business{}), :name, "cannot be deleted")}
  end

  def delete(_record), do: {:ok, :deleted}

  defp business_tree do
    %Business{
      id: "1",
      name: "Acme Corp",
      slug: "acme",
      divisions: [
        %{
          id: "10",
          name: "Core Division",
          departments: [
            %{
              id: "100",
              name: "Platform",
              teams: [
                %{
                  id: "team-1",
                  name: "Enablement",
                  team_members: [
                    %{
                      person: %{
                        id: "person-1",
                        full_name: "Alice One",
                        role: "Engineer",
                        status: "active"
                      },
                      role_in_team: "Lead"
                    }
                  ]
                }
              ],
              knowledge_domains: [
                %{
                  id: "kd-1",
                  name: "Billing",
                  description: "Billing flows",
                  keywords: ["billing"]
                }
              ]
            }
          ]
        }
      ]
    }
  end
end

defmodule LicenseManager.Paid.Ontology.Divisions do
  alias LicenseManager.Paid.Ontology.Division

  def get(id), do: %Division{id: id, name: "Division #{id}"}
  def create(params), do: {:ok, %Division{id: "div-new", name: Map.get(params, "name")}}

  def update(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete(_record), do: {:ok, :deleted}
end

defmodule LicenseManager.Paid.Ontology.Departments do
  alias LicenseManager.Paid.Ontology.Department

  def get(id), do: %Department{id: id, name: "Department #{id}"}

  def create(params),
    do: {:ok, %Department{id: "dept-new", name: Map.get(params, "name"), teams: []}}

  def update(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete(_record), do: {:ok, :deleted}
end

defmodule LicenseManager.Paid.Ontology.Teams do
  alias LicenseManager.Paid.Ontology.Team
  alias LicenseManager.Paid.Ontology.TeamMember

  def get(id), do: %Team{id: id, name: "Team #{id}"}
  def create(params), do: {:ok, %Team{id: "team-new", name: Map.get(params, "name")}}

  def update(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete(_record), do: {:ok, :deleted}

  def add_member(%{team_id: "error"}) do
    {:error,
     Ecto.Changeset.add_error(Ecto.Changeset.change(%TeamMember{}), :team_id, "is invalid")}
  end

  def add_member(attrs), do: {:ok, struct(TeamMember, Map.put(attrs, :id, "tm-1"))}

  def remove_member("error", _person_id), do: {:error, :cannot_remove}
  def remove_member(_team_id, _person_id), do: {:ok, :removed}
end

defmodule LicenseManager.Paid.Ontology.People do
  alias LicenseManager.Paid.Ontology.Channel
  alias LicenseManager.Paid.Ontology.Person

  def list_active do
    [
      %Person{
        id: "person-1",
        full_name: "Alice One",
        email: "alice@example.test",
        role: "Engineer",
        status: "active",
        preferred_channel_id: "chan-1",
        preferred_channel: %{platform: "slack"},
        teams: [%{id: "team-1", name: "Enablement"}]
      }
    ]
  end

  def get(id) do
    %Person{
      id: id,
      full_name: "Alice One",
      email: "alice@example.test",
      role: "Engineer",
      status: "active",
      preferred_channel_id: "chan-1"
    }
  end

  def get_with_channels(id) do
    get(id)
    |> Map.put(:teams, [%{id: "team-1", name: "Enablement"}])
    |> Map.put(:preferred_channel, %{platform: "slack"})
  end

  def list_channels(_id) do
    [
      %Channel{
        id: "chan-1",
        platform: "slack",
        channel_identifier: "@alice",
        person_id: "person-1"
      },
      %Channel{
        id: "chan-2",
        platform: "email",
        channel_identifier: "alice@example.test",
        person_id: "person-1"
      }
    ]
  end

  def set_preferred_channel(_person, "bad") do
    {:error,
     Ecto.Changeset.add_error(
       Ecto.Changeset.change(%Person{}),
       :preferred_channel_id,
       "is invalid"
     )}
  end

  def set_preferred_channel(person, channel_id),
    do: {:ok, %{person | preferred_channel_id: channel_id}}

  def create(params) do
    cs = Person.changeset(%Person{}, params)

    if cs.valid? do
      {:ok, %Person{id: "person-new", full_name: Map.get(params, "full_name"), status: "active"}}
    else
      {:error, cs}
    end
  end

  def update(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete(_record), do: {:ok, :deleted}

  def add_channel(params),
    do:
      {:ok,
       %Channel{
         id: "chan-new",
         platform: Map.get(params, "platform"),
         person_id: Map.get(params, "person_id")
       }}

  def update_channel(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete_channel(_record), do: {:ok, :deleted}
end

defmodule LicenseManager.Paid.Ontology.KnowledgeDomains do
  alias LicenseManager.Paid.Ontology.KnowledgeDomain

  def list_by_business(_business_id) do
    [
      %KnowledgeDomain{
        id: "kd-1",
        name: "Billing",
        description: "Billing flows",
        keywords: ["billing", "invoices"],
        department: %{name: "Platform", division: %{name: "Core Division"}}
      }
    ]
  end

  def get(id), do: %KnowledgeDomain{id: id, name: "Domain #{id}", keywords: []}

  def create(params) do
    cs = KnowledgeDomain.changeset(%KnowledgeDomain{}, params)

    if cs.valid? do
      {:ok,
       %KnowledgeDomain{
         id: "kd-new",
         name: Map.get(params, "name"),
         keywords: Map.get(params, "keywords", [])
       }}
    else
      {:error, cs}
    end
  end

  def update(record, params),
    do: {:ok, struct(record, Map.new(params, fn {k, v} -> {String.to_atom(k), v} end))}

  def delete(_record), do: {:ok, :deleted}
end
