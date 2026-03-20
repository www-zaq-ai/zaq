defmodule Zaq.SystemTest do
  use Zaq.DataCase, async: false

  alias Zaq.System
  alias Zaq.System.EmailConfig
  alias Zaq.System.TelemetryConfig

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
      assert config.transport_mode == "starttls"
      assert config.tls == "enabled"
      assert config.tls_verify == "verify_peer"
      assert config.ca_cert_path == nil
      assert config.from_email == "noreply@zaq.local"
      assert config.from_name == "ZAQ"
    end

    test "returns stored values from DB" do
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.enabled", "true")
      System.set_config("email.port", "465")
      System.set_config("email.transport_mode", "ssl")
      System.set_config("email.tls_verify", "verify_none")
      System.set_config("email.ca_cert_path", "/etc/ssl/certs/custom-ca.pem")

      config = System.get_email_config()
      assert config.relay == "smtp.example.com"
      assert config.enabled == true
      assert config.port == 465
      assert config.transport_mode == "ssl"
      assert config.tls_verify == "verify_none"
      assert config.ca_cert_path == "/etc/ssl/certs/custom-ca.pem"
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
      System.set_config("email.transport_mode", "starttls")
      System.set_config("email.tls", "enabled")

      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:relay] == "smtp.example.com"
      assert opts[:port] == 587
      assert opts[:ssl] == false
      assert opts[:tls] == :if_available
      assert opts[:adapter] == Swoosh.Adapters.SMTP
    end

    test "maps supported tls values and defaults unknown values" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")

      System.set_config("email.tls", "always")
      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:tls] == :always

      System.set_config("email.tls", "never")
      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:tls] == :never

      System.set_config("email.tls", "legacy-or-invalid")
      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:tls] == :if_available
    end

    test "uses ssl transport mode when configured" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.transport_mode", "ssl")
      System.set_config("email.port", "465")

      assert {:ok, opts} = System.email_delivery_opts()
      assert opts[:ssl] == true
      assert opts[:tls] == :never
    end

    test "maps tls_verify and ca_cert_path into tls_options" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.transport_mode", "starttls")
      System.set_config("email.tls", "always")

      System.set_config("email.tls_verify", "verify_none")
      assert {:ok, opts} = System.email_delivery_opts()
      assert Keyword.get(opts[:tls_options], :verify) == :verify_none

      System.set_config("email.tls_verify", "verify_peer")
      System.set_config("email.ca_cert_path", "/etc/ssl/certs/custom.pem")
      assert {:ok, opts} = System.email_delivery_opts()
      assert Keyword.get(opts[:tls_options], :verify) == :verify_peer
      assert Keyword.get(opts[:tls_options], :cacertfile) == ~c"/etc/ssl/certs/custom.pem"
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

    test "returns error when encrypted password cannot be decrypted" do
      System.set_config("email.enabled", "true")
      System.set_config("email.relay", "smtp.example.com")
      System.set_config("email.username", "user@example.com")
      System.set_config("email.password", "enc:v1:broken:payload")

      assert {:error, :invalid_ciphertext} = System.email_delivery_opts()
    end
  end

  describe "password encryption" do
    setup do
      previous_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, previous_config)
      end)

      :ok
    end

    test "encrypts password on save when encryption key is configured" do
      Application.put_env(
        :zaq,
        Zaq.System.SecretConfig,
        encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        key_id: "test-v1"
      )

      changeset =
        EmailConfig.changeset(%EmailConfig{}, %{
          enabled: true,
          relay: "smtp.example.com",
          from_email: "noreply@example.com",
          password: "very-secret"
        })

      assert {:ok, _} = Zaq.System.save_email_config(changeset)
      encrypted = Zaq.System.get_config("email.password")
      assert String.starts_with?(encrypted, "enc:test-v1:")
      assert Zaq.System.get_email_config().password == "very-secret"
    end

    test "fails save when encryption key is missing and password is present" do
      Application.put_env(:zaq, Zaq.System.SecretConfig, [])

      changeset =
        EmailConfig.changeset(%EmailConfig{}, %{
          enabled: true,
          relay: "smtp.example.com",
          from_email: "noreply@example.com",
          password: "very-secret"
        })

      assert {:error, :missing_encryption_key} = Zaq.System.save_email_config(changeset)
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

  describe "get_telemetry_config/0" do
    test "returns TelemetryConfig defaults when no rows exist" do
      config = System.get_telemetry_config()
      assert %TelemetryConfig{} = config
      assert config.capture_infra_metrics == false
      assert config.request_duration_threshold_ms == 10
      assert config.repo_query_duration_threshold_ms == 5
    end

    test "returns stored telemetry values from DB" do
      System.set_config("telemetry.capture_infra_metrics", "false")
      System.set_config("telemetry.request_duration_threshold_ms", "250")
      System.set_config("telemetry.repo_query_duration_threshold_ms", "15")

      config = System.get_telemetry_config()
      assert config.capture_infra_metrics == false
      assert config.request_duration_threshold_ms == 250
      assert config.repo_query_duration_threshold_ms == 15
    end
  end

  describe "save_telemetry_config/1" do
    test "persists valid telemetry changeset to DB" do
      changeset =
        TelemetryConfig.changeset(%TelemetryConfig{}, %{
          capture_infra_metrics: false,
          request_duration_threshold_ms: 500,
          repo_query_duration_threshold_ms: 30
        })

      assert {:ok, saved} = System.save_telemetry_config(changeset)
      assert saved.capture_infra_metrics == false
      assert saved.request_duration_threshold_ms == 500
      assert saved.repo_query_duration_threshold_ms == 30

      assert System.get_config("telemetry.capture_infra_metrics") == "false"
      assert System.get_config("telemetry.request_duration_threshold_ms") == "500"
      assert System.get_config("telemetry.repo_query_duration_threshold_ms") == "30"
    end

    test "returns error for invalid telemetry changeset" do
      changeset =
        TelemetryConfig.changeset(%TelemetryConfig{}, %{
          request_duration_threshold_ms: -1,
          repo_query_duration_threshold_ms: -10
        })

      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_telemetry_config(changeset)
    end
  end
end
