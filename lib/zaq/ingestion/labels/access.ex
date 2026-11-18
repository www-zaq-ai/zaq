defmodule Zaq.Ingestion.Labels.Access do
  @moduledoc "Authorization for BO label operations; derives bypass from the current user record."
  alias Zaq.Accounts.{BOActor, People}
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  import Ecto.Query

  @doc "Document IDs allowed for a user already verified by user/1; never accepts a client bypass."
  def document_ids_query(actor, user, right \\ :read)

  def document_ids_query(_actor, %{role: %{name: "super_admin"}}, _right),
    do: from(d in Document, select: d.id)

  def document_ids_query(actor, _user, right) do
    person = actor[:person_id] && People.get_person(actor[:person_id])

    grants =
      from p in Permissions.grants_query(Permissions.access(person, right)),
        where: p.resource_type == "document",
        select: p.resource_id

    from d in Document, where: fragment("?::text", d.id) in subquery(grants), select: d.id
  end

  @spec user(map() | nil) :: {:ok, struct()} | {:error, atom()}
  def user(actor), do: BOActor.current_user(actor)

  @spec manager(map() | nil) :: :ok | {:error, atom()}
  def manager(actor) do
    with {:ok, user} <- user(actor) do
      if user.role.name in ["super_admin", "admin"], do: :ok, else: {:error, :forbidden}
    end
  end

  @spec resource(map() | nil, struct(), atom()) :: :ok | {:error, atom()}
  def resource(actor, document, right) do
    with {:ok, user} <- user(actor) do
      person = actor[:person_id] && People.get_person(actor[:person_id])

      if Permissions.can?(person, right, document,
           skip_permissions: user.role.name == "super_admin"
         ),
         do: :ok,
         else: {:error, :forbidden}
    end
  end
end
