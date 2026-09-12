defmodule Zaq.System.PeopleAccessConfig do
  @moduledoc """
  Typed People access settings and their canonical defaults.

  This embedded schema validates configuration only; it does not implement OTP,
  rate limiting, or sessions. Durations are seconds and counts are positive integers.
  OTP length is fixed at eight digits and is deliberately not a setting.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :otp_validity_seconds, :integer, default: 300
    field :otp_max_attempts, :integer, default: 5
    field :unknown_email_attempt_limit, :integer, default: 10
    field :unknown_email_window_seconds, :integer, default: 600
    field :unknown_email_cooldown_seconds, :integer, default: 900
    field :otp_send_person_limit, :integer, default: 5
    field :otp_send_ip_limit, :integer, default: 20
    field :otp_send_window_seconds, :integer, default: 900
    field :session_lifetime_seconds, :integer, default: 604_800
  end

  @type t :: %__MODULE__{}

  @doc """
  Validates known atom or string keys (atom keys take precedence if both occur).
  Unknown keys are ignored without interning atoms. Only integers and complete
  decimal integer strings are accepted; floats, blanks and containers are invalid.
  Missing attributes preserve the supplied config. Invalid containers are rejected,
  including client-supplied structs/changesets.
  """
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(config, attrs) when is_map(attrs) and not is_struct(attrs) do
    fields = __schema__(:fields)

    params =
      Enum.reduce(fields, %{}, fn field, acc ->
        case Map.fetch(attrs, field) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> copy_string_attr(acc, attrs, field)
        end
      end)

    normalized = Map.new(params, fn {field, value} -> {field, strict_integer(value)} end)
    changeset = cast(config, normalized, fields, empty_values: []) |> validate_required(fields)
    changeset = Enum.reduce(fields, changeset, &validate_number(&2, &1, greater_than: 0))

    # Retain scalar input for form feedback, but never pass containers to HTML inputs.
    form_params =
      Map.new(params, fn {field, value} -> {Atom.to_string(field), form_value(value)} end)

    %{changeset | params: form_params}
  end

  def changeset(config, _attrs),
    do: config |> change() |> add_error(:base, "must be a map of settings")

  defp copy_string_attr(acc, attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> Map.put(acc, field, value)
      :error -> acc
    end
  end

  defp strict_integer(value) when is_integer(value), do: value

  defp strict_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp strict_integer(_value), do: nil

  defp form_value(value) when is_binary(value) or is_number(value), do: value
  defp form_value(_value), do: nil
end
