defmodule Zaq.SystemTest do
  use Zaq.DataCase, async: true

  alias Zaq.System
  alias Zaq.System.EmailConfig

  describe "get_config/1 and set_config/2" do
    test "returns nil for unknown key" do
      assert is_nil(System.get_config("nonexistent.key"))
    end

    test "set_config/2 inserts a new key-value" do
      assert {:ok, _} = System.set_config("test.key", "hello")
      assert System.get_config("test.key") == "hello"
    end

    test "set_config/2 updates an existing key" do
      System.set_config("test.update", "first")
      assert {:ok, _} = System.set_config("test.update", "second")
      assert System.get_config("test.update") == "second"
    end

    test "set_config/2 coerces non-string values to string" do
      System.set_config("test.int", 42)
      assert System.get_config("test.int") == "42"
    end
  end

  describe "get_email_config/0" do
    test "returns an EmailConfig struct with defaults when no rows exist" do
      config = System.get_email_config()
      assert %EmailConfig{} = config
      assert config.enabled == false
      assert config.port == 587
      assert config.tls == "enabled"
      assert config.from_email == "noreply@zaq.local"
      assert config.from_name == "ZAQ"
    end

    test "returns stored values from DB" do
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.enabled", "true")
      System.set_config("email.port", "465")

      config = System.get_email_config()
      assert config.relay == "smtp.example.com"
      assert config.enabled == true
      assert config.port == 465
    end
  end

  describe "save_email_config/1" do
    test "persists valid changeset to DB" do
      config = %EmailConfig{}

      changeset =
        EmailConfig.changeset(config, %{
          enabled: true,
          relay: "smtp.example.com",
          from_email: "noreply@example.com"
        })

      assert {:ok, saved} = System.save_email_config(changeset)
      assert saved.relay == "smtp.example.com"

      assert System.get_config("email.relay") == "smtp.example.com"
    end

    test "returns error for invalid changeset" do
      changeset =
        EmailConfig.changeset(%EmailConfig{}, %{enabled: true})

      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_email_config(changeset)
    end
  end

  describe "email_delivery_opts/0" do
    test "returns :not_configured when email disabled" do
      System.set_config("email.enabled", "false")
      assert {:error, :not_configured} = System.email_delivery_opts()
    end

    test "returns :not_configured when relay is blank" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "")
      assert {:error, :not_configured} = System.email_delivery_opts()
    end

    test "returns keyword list when enabled with relay set" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.port", "587")
      System.set_config("email.tls", "enabled")

      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:relay] == "smtp.example.com"
      assert opts[:port] == 587
      assert opts[:tls] == :enabled
      assert opts[:adapter] == Swoosh.Adapters.SMTP
    end

    test "sets auth :never when username is blank" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.username", "")

      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:auth] == :never
    end

    test "sets auth :always and includes credentials when username is set" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.username", "user@example.com")
      System.set_config("email.password", "secret")

      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:auth] == :always
      assert opts[:username] == "user@example.com"
      assert opts[:password] == "secret"
    end
  end

  describe "email_sender/0" do
    test "returns defaults when not configured" do
      assert {"ZAQ", "noreply@zaq.local"} = System.email_sender()
    end

    test "returns stored from_name and from_email" do
      System.set_config("email.from_name", "My App")
      System.set_config("email.from_email", "hello@myapp.com")

      assert {"My App", "hello@myapp.com"} = System.email_sender()
    end
  end
end
