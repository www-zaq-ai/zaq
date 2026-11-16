defmodule Zaq.DatabaseConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.DatabaseConfig

  @moduletag :tmp_dir
  @url "postgresql://owner:ephemeral%40password@localhost:5432/zaq"
  @script Path.expand("../../scripts/database_url.py", __DIR__)

  test "Repo initialization preserves component config and URL option precedence" do
    config = [hostname: "localhost", username: "owner", pool_size: 10]
    assert Zaq.Repo.init(:supervisor, config) == {:ok, config}

    {:ok, parsed} = Zaq.Repo.init(:supervisor, config ++ [url: @url <> "?ssl=true&pool_size=3"])
    assert parsed[:ssl] == true
    assert parsed[:pool_size] == 3
    refute Keyword.has_key?(parsed, :url)
    refute Keyword.has_key?(parsed, :database_ssl_ca_cert_file)
  end

  test "absent TLS keeps the existing connection configuration" do
    config = DatabaseConfig.from_url!(@url, nil)
    refute Keyword.has_key?(config, :ssl)
    assert config[:username] == "owner"
    assert config[:password] == "ephemeral@password"
  end

  test "Ecto parses URL TLS booleans and connection tuning" do
    config = DatabaseConfig.from_url!(@url <> "?ssl=true&pool_size=3", nil)
    assert config[:ssl] == true
    assert config[:pool_size] == 3
    assert DatabaseConfig.from_url!(@url <> "?ssl=false", nil)[:ssl] == false
  end

  test "a custom CA enables peer and hostname verification", %{tmp_dir: dir} do
    # The connection integration verifies certificate contents and trust.
    ca = Path.join(dir, "ca.pem")
    File.write!(ca, "certificate fixture")
    ssl = DatabaseConfig.from_url!(@url <> "?ssl=true", ca)[:ssl]
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacertfile] == ca
    assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
  end

  test "invalid TLS and URL errors contain no supplied values" do
    for url <- [
          "postgresql://owner:secret@host",
          @url <> "?ssl=secret",
          @url <> "?ssl=true&ssl=false",
          @url <> "?sslmode=require",
          @url <> "?ssl_opts=secret",
          @url <> "?timeout=secret"
        ] do
      error = assert_raise ArgumentError, fn -> DatabaseConfig.from_url!(url, nil) end
      refute Exception.message(error) =~ "secret"
      refute Exception.message(error) =~ "password"
      refute Exception.message(error) =~ url
    end
  end

  test "CA requires TLS and an accessible file" do
    assert_raise ArgumentError, ~r/requires.*ssl=true/, fn ->
      DatabaseConfig.from_url!(@url, "/missing/private-value")
    end

    error =
      assert_raise ArgumentError, fn ->
        DatabaseConfig.from_url!(@url <> "?ssl=true", "/missing/private-value")
      end

    refute Exception.message(error) =~ "private-value"
  end

  test "generated URLs preserve defaults and accept explicit TLS booleans" do
    for {setting, suffix} <- [{nil, ""}, {"", ""}, {"true", "?ssl=true"}, {"false", "?ssl=false"}] do
      assert url_command("build", [{"ZAQ_DATABASE_SSL", setting}]) == {@url <> suffix <> "\n", 0}
    end
  end

  test "invalid generated TLS fails without exposing values" do
    for setting <- ["1", "TRUE", "require", " secret "] do
      {output, status} = url_command("build", [{"ZAQ_DATABASE_SSL", setting}])
      assert status != 0
      assert output == "ZAQ_DATABASE_SSL must be true or false.\n"
    end
  end

  test "reserved and Unicode component characters retain their identity" do
    user = "owner:@/?#%é"
    password = "pass:'\"@/\\?#% +é"
    database = "db/?#% +é"

    {url, 0} =
      url_command("build", [
        {"ZAQ_OWNER", user},
        {"ZAQ_OWNER_PASSWORD", password},
        {"ZAQ_DATABASE", database}
      ])

    config = DatabaseConfig.from_url!(String.trim(url), nil)
    assert {config[:username], config[:password], config[:database]} == {user, password, database}
  end

  test "IPv6 component hosts are bracketed exactly once" do
    for host <- ["::1", "[::1]"] do
      {url, 0} = url_command("build", [{"PGHOST", host}])
      assert URI.parse(String.trim(url)).host == "::1"
    end
  end

  property "generated credentials and database names round trip through Ecto" do
    check all(
            user <- string(:printable, min_length: 1, max_length: 30),
            password <- string(:printable, min_length: 1, max_length: 50),
            database <- string(:printable, min_length: 1, max_length: 30),
            max_runs: 30
          ) do
      {url, 0} =
        url_command("build", [
          {"ZAQ_OWNER", user},
          {"ZAQ_OWNER_PASSWORD", password},
          {"ZAQ_DATABASE", database}
        ])

      config = DatabaseConfig.from_url!(String.trim_trailing(url, "\n"), nil)
      assert config[:username] == user
      assert config[:password] == password
      assert config[:database] == database
    end
  end

  test "libpq translation requires verified TLS and removes Ecto pool options" do
    {url, 0} =
      url_command("libpq", [{"DATABASE_URL", @url <> "?ssl=true&pool_size=2&timeout=1000"}])

    query = url |> String.trim() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query == %{"sslmode" => "verify-full", "sslrootcert" => "system"}

    {url, 0} =
      url_command("libpq", [
        {"DATABASE_URL", @url <> "?ssl=true"},
        {"ZAQ_DATABASE_SSL_CA_CERT_FILE", "/mounted/ca file.pem"}
      ])

    assert URI.decode_query(URI.parse(String.trim(url)).query)["sslrootcert"] ==
             "/mounted/ca file.pem"

    assert url =~ "ca%20file.pem"
  end

  test "libpq preserves non-TLS defaults and rejects ambiguous TLS and unknown options" do
    assert {@url <> "\n", 0} = url_command("libpq", [{"DATABASE_URL", @url}])

    assert {@url <> "?sslmode=disable\n", 0} =
             url_command("libpq", [{"DATABASE_URL", @url <> "?ssl=false"}])

    for query <- [
          "ssl=secret",
          "ssl=true&sslmode=disable",
          "ssl=true&ssl=false",
          "unknown=secret"
        ] do
      {output, status} = url_command("libpq", [{"DATABASE_URL", @url <> "?" <> query}])
      assert status != 0
      refute output =~ "secret"
      refute output =~ "ephemeral"
    end
  end

  test "libpq parser errors and CA conflicts never echo inputs" do
    for {url, ca} <- [
          {"postgresql://owner:private-secret@[invalid/zaq", nil},
          {@url, "/private-secret/ca.pem"},
          {@url <> "?ssl=false", "/private-secret/ca.pem"}
        ] do
      {output, status} =
        url_command("libpq", [
          {"DATABASE_URL", url},
          {"ZAQ_DATABASE_SSL_CA_CERT_FILE", ca}
        ])

      assert status != 0
      refute output =~ "private-secret"
      refute output =~ "ephemeral"
    end
  end

  defp url_command(mode, overrides) do
    env = [
      {"DATABASE_URL", nil},
      {"ZAQ_DATABASE_SSL", nil},
      {"ZAQ_DATABASE_SSL_CA_CERT_FILE", nil},
      {"PGHOST", "localhost"},
      {"PGPORT", "5432"},
      {"ZAQ_OWNER", "owner"},
      {"ZAQ_OWNER_PASSWORD", "ephemeral@password"},
      {"ZAQ_DATABASE", "zaq"}
    ]

    System.cmd("python3", [@script, mode],
      env: Map.to_list(Map.merge(Map.new(env), Map.new(overrides))),
      stderr_to_stdout: true
    )
  end
end
