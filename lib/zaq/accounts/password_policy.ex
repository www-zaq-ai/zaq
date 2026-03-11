defmodule Zaq.Accounts.PasswordPolicy do
  @moduledoc false

  import Ecto.Changeset

  @min_length 8
  @max_length 72

  @requirements [
    %{id: :min_length, label: "At least #{@min_length} characters"},
    %{id: :max_length, label: "No more than #{@max_length} characters"},
    %{id: :lowercase, label: "At least one lowercase letter"},
    %{id: :uppercase, label: "At least one uppercase letter"},
    %{id: :digit, label: "At least one number"},
    %{id: :symbol, label: "At least one special character"}
  ]

  def min_length, do: @min_length

  def max_length, do: @max_length

  def requirements, do: @requirements

  def requirements_with_status(password) do
    password = password || ""

    Enum.map(@requirements, fn requirement ->
      Map.put(requirement, :met?, requirement_met?(requirement.id, password))
    end)
  end

  def valid_password?(password) when is_binary(password) do
    Enum.all?(@requirements, fn requirement -> requirement_met?(requirement.id, password) end)
  end

  def valid_password?(_), do: false

  def validate(changeset, field \\ :password) do
    changeset
    |> validate_length(field, min: @min_length, max: @max_length)
    |> validate_change(field, &character_mix_errors/2)
  end

  defp character_mix_errors(field, password) when is_binary(password) do
    []
    |> maybe_add_error(
      field,
      String.match?(password, ~r/[a-z]/),
      "must include at least one lowercase letter"
    )
    |> maybe_add_error(
      field,
      String.match?(password, ~r/[A-Z]/),
      "must include at least one uppercase letter"
    )
    |> maybe_add_error(field, String.match?(password, ~r/\d/), "must include at least one number")
    |> maybe_add_error(
      field,
      String.match?(password, ~r/[^A-Za-z0-9]/),
      "must include at least one special character"
    )
    |> Enum.reverse()
  end

  defp character_mix_errors(_field, _password), do: []

  defp maybe_add_error(errors, _field, true, _message), do: errors

  defp maybe_add_error(errors, field, false, message), do: [{field, message} | errors]

  defp requirement_met?(:min_length, password), do: String.length(password) >= @min_length

  defp requirement_met?(:max_length, password), do: String.length(password) <= @max_length

  defp requirement_met?(:lowercase, password), do: String.match?(password, ~r/[a-z]/)

  defp requirement_met?(:uppercase, password), do: String.match?(password, ~r/[A-Z]/)

  defp requirement_met?(:digit, password), do: String.match?(password, ~r/\d/)

  defp requirement_met?(:symbol, password), do: String.match?(password, ~r/[^A-Za-z0-9]/)
end
