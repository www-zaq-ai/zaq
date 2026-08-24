defmodule Zaq.Channels.EmailBridge.ImapAdapter.MimeParts do
  @moduledoc """
  Converts Mailroom BODYSTRUCTURE parts into IMAP section descriptors.

  Descriptors are JSON-safe maps that identify MIME body or attachment parts by
  their IMAP numeric section. Mailroom assigns `nil` to a single-part root body;
  IMAP section `1` is used for that root leaf so body fetching still works for
  non-multipart messages. Other missing or malformed sections are ignored.
  """

  alias Mailroom.IMAP.BodyStructure.Part

  @section_regex ~r/^[1-9]\d*(?:\.[1-9]\d*)*$/

  @type descriptor :: %{
          section: String.t(),
          content_type: String.t(),
          filename: String.t() | nil,
          encoding: String.t() | nil,
          encoded_size: non_neg_integer() | nil,
          disposition: String.t() | nil,
          content_id: String.t() | nil,
          params: map()
        }

  @spec body_parts(term()) :: [descriptor()]
  def body_parts(body_structure) do
    body_structure
    |> flatten_parts()
    |> Enum.filter(&body_part?/1)
    |> Enum.map(&descriptor/1)
  end

  @spec attachment_parts(term()) :: [descriptor()]
  def attachment_parts(body_structure) do
    body_structure
    |> flatten_parts()
    |> Enum.filter(&attachment_part?/1)
    |> Enum.map(&descriptor/1)
  end

  @spec plain_text_part(term()) :: descriptor() | nil
  def plain_text_part(body_structure), do: first_body_part(body_structure, "text/plain")

  @spec html_part(term()) :: descriptor() | nil
  def html_part(body_structure), do: first_body_part(body_structure, "text/html")

  @spec valid_section?(term()) :: boolean()
  def valid_section?(section) when is_binary(section), do: Regex.match?(@section_regex, section)
  def valid_section?(_section), do: false

  defp first_body_part(body_structure, content_type) do
    body_structure
    |> body_parts()
    |> Enum.find(&(&1.content_type == content_type))
  end

  defp flatten_parts(body_structure), do: flatten_parts(body_structure, root?: true)

  defp flatten_parts(%Part{parts: parts} = part, _opts) when is_list(parts) and parts != [] do
    Enum.flat_map(parts, &flatten_parts(&1, root?: false)) ++ [{part, nil}]
  end

  defp flatten_parts(%Part{} = part, opts) do
    default_section = if Keyword.get(opts, :root?), do: "1"
    [{part, default_section}]
  end

  defp flatten_parts(parts, _opts) when is_list(parts),
    do: Enum.flat_map(parts, &flatten_parts(&1, root?: false))

  defp flatten_parts(_, _opts), do: []

  defp body_part?({%Part{multipart: true}, _default_section}), do: false

  defp body_part?({%Part{} = part, default_section}) do
    content_type(part) in ["text/plain", "text/html"] and not file_semantics?(part) and
      valid_section?(section(part, default_section))
  end

  defp attachment_part?({%Part{multipart: true}, _default_section}), do: false

  defp attachment_part?({%Part{} = part, default_section}),
    do: file_semantics?(part) and valid_section?(section(part, default_section))

  defp file_semantics?(%Part{} = part) do
    disposition = disposition(part)

    disposition == "attachment" or
      (disposition == "inline" and present?(filename(part))) or
      present?(filename(part))
  end

  defp descriptor({%Part{} = part, default_section}) do
    %{
      section: section(part, default_section),
      content_type: content_type(part),
      filename: filename(part),
      encoding: normalize_string(part.encoding),
      encoded_size: part.encoded_size,
      disposition: disposition(part),
      content_id: normalize_content_id(part.id),
      params: normalize_params(part.params)
    }
  end

  defp section(%Part{section: section}, _default_section) when is_integer(section),
    do: Integer.to_string(section)

  defp section(%Part{section: section}, _default_section) when is_binary(section), do: section
  defp section(_part, default_section), do: default_section

  defp content_type(%Part{type: {major, minor}}),
    do: "#{normalize_string(major) || "application"}/#{normalize_string(minor) || "octet-stream"}"

  defp content_type(%Part{type: type}) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "application/octet-stream"
      value -> if String.contains?(value, "/"), do: value, else: "application/#{value}"
    end
  end

  defp content_type(_part), do: "application/octet-stream"

  defp disposition(%Part{disposition: disposition}), do: normalize_string(disposition)

  defp filename(%Part{file_name: file_name, params: params}) do
    first_present([file_name, param(params, "filename"), param(params, "name")], downcase?: false)
  end

  defp param(params, key) when is_map(params) do
    params
    |> normalize_params()
    |> Map.get(String.downcase(key))
  end

  defp param(_params, _key), do: nil

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {key |> to_string() |> String.downcase(), value} end)
  end

  defp normalize_params(_params), do: %{}

  defp normalize_content_id(nil), do: nil

  defp normalize_content_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> blank_to_nil()
  end

  defp first_present(values, opts) do
    Enum.find_value(values, fn value ->
      value = normalize_string(value, opts)
      if present?(value), do: value
    end)
  end

  defp normalize_string(value, opts \\ [])
  defp normalize_string(nil, _opts), do: nil

  defp normalize_string(value, opts) do
    value
    |> to_string()
    |> String.trim()
    |> maybe_downcase(Keyword.get(opts, :downcase?, true))
    |> blank_to_nil()
  end

  defp maybe_downcase(value, true), do: String.downcase(value)
  defp maybe_downcase(value, false), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
