defmodule Zaq.Utils.EmailUtils do
  @moduledoc false

  @default_domain "zaq.local"
  @default_references_cap 20

  @doc """
  Strips angle brackets and whitespace from an RFC 2822 Message-ID value.
  Returns `nil` for blank or non-binary input.
  """
  def normalize_message_id(nil), do: nil

  def normalize_message_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_message_id(_), do: nil

  @doc """
  Mints a new RFC 5322 Message-ID for an outbound-first email.

  Returned in the same normalized (bracket-less) form `normalize_message_id/1`
  produces, so a minted id and an id parsed from received headers are stored
  identically and compare directly. Angle brackets are added at emission time.
  """
  def new_message_id(domain) do
    "zaq-#{Ecto.UUID.generate()}@#{resolve_domain(domain)}"
  end

  @doc """
  Extracts the domain from a sending address, falling back when it is missing,
  blank, or not an address. Accepts a bare address or a `Name <addr>` form.
  """
  def sending_domain(from_email, fallback \\ @default_domain)

  def sending_domain(from_email, fallback) when is_binary(from_email) do
    from_email
    |> String.trim()
    |> String.trim_trailing(">")
    |> String.split("@")
    |> case do
      [_local, domain] -> blank_to_nil(domain) || fallback
      _ -> fallback
    end
  end

  def sending_domain(_from_email, fallback), do: fallback

  @doc """
  Coerces a `references` value into a normalized list of message-ids.

  The IMAP parser stores `references` as a space-joined string while the
  outbound path stores a list, so every reader must normalize before use.
  """
  def normalize_references_list(nil), do: []

  def normalize_references_list(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> normalize_references_list()
  end

  def normalize_references_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_references_list(_), do: []

  @doc """
  Caps a `References` chain to bound header growth on long sequences.

  Keeps the head plus the last `max` entries, per RFC 5322 §3.6.4 guidance. The
  head is always preserved because the thread root is derived from it.
  """
  def cap_references(refs, max \\ @default_references_cap) do
    refs = normalize_references_list(refs)

    if length(refs) <= max do
      refs
    else
      [head | rest] = refs
      [head | Enum.take(rest, -max)]
    end
  end

  defp resolve_domain(domain) when is_binary(domain) do
    blank_to_nil(domain) || @default_domain
  end

  defp resolve_domain(_), do: @default_domain

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
