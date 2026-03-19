defmodule Zaq.System.EmailConfigTest do
  use Zaq.DataCase, async: true

  alias Zaq.System.EmailConfig

  defp base_config, do: %EmailConfig{}

  describe "changeset/2" do
    test "valid when enabled is false with no relay" do
      changeset = EmailConfig.changeset(base_config(), %{enabled: false})
      assert changeset.valid?
    end

    test "valid when enabled is true with relay and from_email" do
      attrs = %{
        enabled: true,
        relay: "smtp.example.com",
        from_email: "noreply@example.com"
      }

      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "invalid when enabled is true without relay" do
      attrs = %{enabled: true, from_email: "noreply@example.com"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{relay: _} = errors_on(changeset)
    end

    test "invalid with bad from_email format" do
      attrs = %{enabled: false, from_email: "not-an-email"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{from_email: _} = errors_on(changeset)
    end

    test "invalid with port 0" do
      attrs = %{enabled: false, port: 0}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{port: _} = errors_on(changeset)
    end

    test "invalid with port greater than 65535" do
      attrs = %{enabled: false, port: 65_536}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{port: _} = errors_on(changeset)
    end

    test "valid with port at boundary 65535" do
      attrs = %{enabled: false, port: 65_535}
      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "invalid with bad tls value" do
      attrs = %{enabled: false, tls: "maybe"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{tls: _} = errors_on(changeset)
    end

    test "valid with tls set to always" do
      attrs = %{enabled: false, tls: "always"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "valid with tls set to never" do
      attrs = %{enabled: false, tls: "never"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "valid with transport mode set to ssl" do
      attrs = %{enabled: false, transport_mode: "ssl"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "invalid with bad transport mode" do
      attrs = %{enabled: false, transport_mode: "invalid"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{transport_mode: _} = errors_on(changeset)
    end

    test "valid with tls_verify set to verify_none" do
      attrs = %{enabled: false, tls_verify: "verify_none"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      assert changeset.valid?
    end

    test "invalid with bad tls_verify value" do
      attrs = %{enabled: false, tls_verify: "strict"}
      changeset = EmailConfig.changeset(base_config(), attrs)
      refute changeset.valid?
      assert %{tls_verify: _} = errors_on(changeset)
    end
  end
end
