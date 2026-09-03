defmodule Zaq.Contracts.Record.Authorization do
  @moduledoc """
  Generic actor authorization for Records that carry normalized permission Records.
  """

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Contracts.Record
  alias Zaq.Identity.ActorNormalizer

  @spec can?(Person.t() | map() | nil, Record.t(), atom()) :: boolean()
  def can?(%Person{} = person, %Record{permissions: permissions}, right)
      when is_list(permissions) do
    Enum.any?(permissions, &permission_matches?(&1, person, right))
  end

  def can?(actor, %Record{} = record, right) do
    with person_id when not is_nil(person_id) <- ActorNormalizer.person_id(actor),
         person when not is_nil(person) <- People.get_person_with_channels(person_id) do
      can?(person, record, right)
    else
      _ -> false
    end
  end

  def can?(_actor, _record, _right), do: false

  @spec filter(Person.t() | map() | nil, [Record.t()], atom()) :: [Record.t()]
  def filter(%Person{} = person, records, right) when is_list(records) do
    Enum.filter(records, &(can?(person, &1, right) == true))
  end

  def filter(actor, records, right) when is_list(records) do
    with person_id when not is_nil(person_id) <- ActorNormalizer.person_id(actor),
         person when not is_nil(person) <- People.get_person_with_channels(person_id) do
      filter(person, records, right)
    else
      _ -> []
    end
  end

  def filter(_actor, _records, _right), do: []

  defp permission_matches?(%Record{attributes: attrs}, person, right) when is_map(attrs) do
    principal_matches?(attrs, person) and right in access_rights(attrs)
  end

  defp permission_matches?(_permission, _person, _right), do: false

  defp principal_matches?(attrs, person) do
    case principal(attrs) do
      {"email", identifier} ->
        normalized(identifier) == normalized(person.email) or
          Enum.any?(person_channels(person), &channel_matches?(&1, "email", identifier))

      {channel, identifier} ->
        Enum.any?(person_channels(person), &channel_matches?(&1, channel, identifier))

      _ ->
        false
    end
  end

  defp channel_matches?(channel, platform, identifier) do
    channel.platform == platform and
      normalized(channel.channel_identifier) == normalized(identifier)
  end

  defp person_channels(%Person{channels: channels}) when is_list(channels), do: channels
  defp person_channels(_person), do: []

  defp principal(attrs) do
    case get(attrs, "principal") do
      %{} = principal ->
        channel = get(principal, "channel") || get(principal, "type")
        identifier = get(principal, "identifier") || get(principal, "key")
        normalized_principal(channel, identifier)

      _ ->
        channel = get(attrs, "principal_channel") || get(attrs, "principal_type")
        normalized_principal(channel, get(attrs, "principal_key"))
    end
  end

  defp normalized_principal(channel, identifier)
       when is_binary(channel) and is_binary(identifier) and channel != "" and identifier != "" do
    {String.downcase(String.trim(channel)), String.trim(identifier)}
  end

  defp normalized_principal(_channel, _identifier), do: nil

  defp access_rights(attrs) do
    attrs
    |> get("access_rights")
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&canonical_right/1)
  end

  defp canonical_right("read"), do: [:read]
  defp canonical_right("edit"), do: [:edit]
  defp canonical_right("move"), do: [:move]
  defp canonical_right("delete"), do: [:delete]
  defp canonical_right(_right), do: []

  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_value), do: nil

  defp get(map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
