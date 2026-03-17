defmodule Zaq.System.EmailConfig do
  @moduledoc """
  Embedded schema for validating and working with the email (SMTP) configuration form.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @tls_options ~w(enabled always never)

  embedded_schema do
    field :enabled, :boolean, default: false
    field :relay, :string
    field :port, :integer, default: 587
    field :tls, :string, default: "enabled"
    field :username, :string
    field :password, :string
    field :from_email, :string, default: "noreply@zaq.local"
    field :from_name, :string, default: "ZAQ"
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:enabled, :relay, :port, :tls, :username, :password, :from_email, :from_name])
    |> maybe_require_relay()
    |> validate_format(:from_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_inclusion(:tls, @tls_options, message: "must be enabled, always, or never")
  end

  defp maybe_require_relay(changeset) do
    if get_field(changeset, :enabled) do
      validate_required(changeset, [:relay, :from_email],
        message: "is required when email is enabled"
      )
    else
      changeset
    end
  end
end
