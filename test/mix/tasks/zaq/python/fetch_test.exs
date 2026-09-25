defmodule Mix.Tasks.Zaq.Python.FetchTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Bitwise

  alias Mix.Tasks.Zaq.Python.Fetch
  alias Mix.Tasks.Zaq.Python.Fetch.Publisher

  @default_repo "www-zaq-ai/crawler-ingest"
  @reviewed_sha "c726f63fc963f6d0acaaa297a580fc927d0e34ae"
  @expected_files ~w(
    web_crawler.py pipeline.py pdf_to_md.py docx_to_md.py pptx_to_md.py xlsx_to_md.py
    image_dedup.py image_to_text.py clean_md.py inject_descriptions.py
    requirements.txt requirements.lock
  )

  setup do
    original_http_client = Application.get_env(:zaq, :http_client)

    Application.put_env(:zaq, :http_client, Zaq.FetchPythonHTTPClientStub)
    Zaq.FetchPythonHTTPClientStub.clear_responder()

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_fetch_python_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Zaq.FetchPythonHTTPClientStub.clear_responder()

      if is_nil(original_http_client) do
        Application.delete_env(:zaq, :http_client)
      else
        Application.put_env(:zaq, :http_client, original_http_client)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "downloads all files, writes manifest, and chmods .py files when commit is provided", %{
    tmp_dir: tmp_dir
  } do
    assert Fetch.required_files() == @expected_files

    repo = "acme/crawler-ingest"
    sha = "abc123"
    dest = Path.join(tmp_dir, "python")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      if String.starts_with?(url, "https://api.github.com/") do
        raise "unexpected branch resolution call: #{url}"
      end

      if String.starts_with?(url, "https://raw.githubusercontent.com/#{repo}/#{sha}/") do
        filename =
          String.replace_prefix(url, "https://raw.githubusercontent.com/#{repo}/#{sha}/", "")

        {:ok, %{status: 200, body: "# file: #{filename}\n"}}
      else
        raise "unexpected url: #{url}"
      end
    end)

    Fetch.run(["--repo", repo, "--commit", sha, "--dest", dest])

    Enum.each(@expected_files, fn filename ->
      assert File.exists?(Path.join(dest, filename))
    end)

    manifest_path = Path.join(dest, "manifest.json")
    assert File.exists?(manifest_path)

    manifest = manifest_path |> File.read!() |> Jason.decode!()

    assert manifest["repo"] == repo
    assert manifest["commit"] == sha
    assert manifest["files"] == @expected_files
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(manifest["fetched_at"])

    py_mode = File.stat!(Path.join(dest, "web_crawler.py")).mode
    assert (py_mode &&& 0o111) == 0o111

    requirements_mode = File.stat!(Path.join(dest, "requirements.txt")).mode
    assert (requirements_mode &&& 0o111) == 0
  end

  test "fetches the reviewed revision by default without resolving a branch", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "python")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      assert String.starts_with?(
               url,
               "https://raw.githubusercontent.com/#{@default_repo}/#{@reviewed_sha}/"
             )

      {:ok, %{status: 200, body: "reviewed\n"}}
    end)

    Fetch.run(["--dest", dest])

    assert File.read!(Path.join(dest, "requirements.lock")) == "reviewed\n"
    assert Jason.decode!(File.read!(Path.join(dest, "manifest.json")))["commit"] == @reviewed_sha
  end

  test "resolves an explicitly requested branch", %{tmp_dir: tmp_dir} do
    sha = "mainsha123"
    dest = Path.join(tmp_dir, "python")
    branch_url = "https://api.github.com/repos/#{@default_repo}/commits/main"

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, opts ->
      send(self(), {:http_get, url, opts})

      cond do
        url == branch_url ->
          assert Keyword.get(opts, :headers) == [{"User-Agent", "Mix Task"}]
          {:ok, %{status: 200, body: %{"sha" => sha}}}

        String.starts_with?(url, "https://raw.githubusercontent.com/#{@default_repo}/#{sha}/") ->
          {:ok, %{status: 200, body: "ok\n"}}

        true ->
          raise "unexpected url: #{url}"
      end
    end)

    Fetch.run(["--branch", "main", "--dest", dest])

    assert_received {:http_get, ^branch_url, _opts}
    assert File.exists?(Path.join(dest, "manifest.json"))
  end

  test "fails clearly when the default revision is missing", %{tmp_dir: tmp_dir} do
    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      raise "unexpected HTTP request: #{url}"
    end)

    File.cd!(tmp_dir, fn ->
      assert_raise Mix.Error, ~r/crawler-ingest.revision.*missing/, fn ->
        Fetch.run(["--dest", Path.join(tmp_dir, "python")])
      end
    end)
  end

  test "fails clearly when the default revision is malformed", %{tmp_dir: tmp_dir} do
    pin = Path.join(tmp_dir, "priv/python/crawler-ingest.revision")
    File.mkdir_p!(Path.dirname(pin))
    File.write!(pin, "main\n")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      raise "unexpected HTTP request: #{url}"
    end)

    File.cd!(tmp_dir, fn ->
      assert_raise Mix.Error, ~r/crawler-ingest.revision.*full.*SHA/, fn ->
        Fetch.run(["--dest", Path.join(tmp_dir, "python")])
      end
    end)
  end

  test "success replaces the managed tree and removes obsolete files", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "python")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "obsolete.py"), "old")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      filename = Path.basename(url)
      {:ok, %{status: 200, body: "new:#{filename}"}}
    end)

    Fetch.run(["--commit", "abc123", "--dest", dest])

    refute File.exists?(Path.join(dest, "obsolete.py"))
    assert File.read!(Path.join(dest, "requirements.lock")) == "new:requirements.lock"
    assert File.ls!(tmp_dir) == ["python"]
  end

  property "a failed download or write never publishes a partial tree", %{tmp_dir: tmp_dir} do
    check all(
            filename <- member_of(@expected_files),
            existing <- boolean(),
            failure <- member_of([:transport, :write]),
            max_runs: 40
          ) do
      root = Path.join(tmp_dir, "case-#{System.unique_integer([:positive])}")
      dest = Path.join(root, "python")
      File.mkdir_p!(root)

      if existing do
        File.mkdir_p!(dest)
        File.write!(Path.join(dest, "manifest.json"), "old manifest")
        File.write!(Path.join(dest, "old.py"), "old script")
      end

      Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
        if Path.basename(url) == filename do
          case failure do
            :transport -> {:error, :timeout}
            :write -> {:ok, %{status: 200, body: {:invalid, :body}}}
          end
        else
          {:ok, %{status: 200, body: "new"}}
        end
      end)

      result =
        try do
          Fetch.run(["--commit", "abc123", "--dest", dest])
          :ok
        rescue
          error -> {:raised, error}
        end

      assert match?({:raised, _}, result)

      if existing do
        assert File.read!(Path.join(dest, "manifest.json")) == "old manifest"
        assert File.read!(Path.join(dest, "old.py")) == "old script"
        assert File.ls!(root) == ["python"]
      else
        refute File.exists?(dest)
        assert File.ls!(root) == []
      end
    end
  end

  test "each managed download position preserves the old tree on transport or write error", %{
    tmp_dir: tmp_dir
  } do
    for filename <- @expected_files, failure <- [:transport, :write] do
      root = Path.join(tmp_dir, "#{filename}-#{failure}")
      dest = Path.join(root, "python")
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "old.py"), "old script")

      Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
        if Path.basename(url) == filename do
          case failure do
            :transport -> {:error, :timeout}
            :write -> {:ok, %{status: 200, body: {:invalid, :body}}}
          end
        else
          {:ok, %{status: 200, body: "new"}}
        end
      end)

      result =
        try do
          Fetch.run(["--commit", "abc123", "--dest", dest])
          :ok
        rescue
          error -> {:raised, error}
        end

      assert match?({:raised, _}, result)
      assert File.read!(Path.join(dest, "old.py")) == "old script"
      assert File.ls!(root) == ["python"]
    end
  end

  test "publisher restores the previous tree when staging cannot be moved", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "python")
    staging = Path.join(tmp_dir, "missing-stage")

    assert_raise Mix.Error, ~r/Failed to publish/, fn ->
      Publisher.replace(staging, dest)
    end

    refute File.exists?(dest)
    assert File.ls!(tmp_dir) == []

    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "old.py"), "old script")

    assert_raise Mix.Error, ~r/Failed to publish/, fn ->
      Publisher.replace(staging, dest)
    end

    assert File.read!(Path.join(dest, "old.py")) == "old script"
    assert File.ls!(tmp_dir) == ["python"]
  end

  test "raises when branch does not exist", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    branch = "does-not-exist"
    dest = Path.join(tmp_dir, "python")
    branch_url = "https://api.github.com/repos/#{repo}/commits/#{branch}"

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      if url == branch_url do
        {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "Branch '#{branch}' not found in repository '#{repo}'", fn ->
      Fetch.run(["--repo", repo, "--branch", branch, "--dest", dest])
    end
  end

  test "raises when resolving branch sha returns transport error", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    branch = "main"
    dest = Path.join(tmp_dir, "python")
    branch_url = "https://api.github.com/repos/#{repo}/commits/#{branch}"

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      if url == branch_url do
        {:error, :econnrefused}
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "Failed to resolve branch SHA: :econnrefused", fn ->
      Fetch.run(["--repo", repo, "--branch", branch, "--dest", dest])
    end
  end

  test "raises on unexpected branch resolution response", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    branch = "main"
    dest = Path.join(tmp_dir, "python")
    branch_url = "https://api.github.com/repos/#{repo}/commits/#{branch}"

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      if url == branch_url do
        {:ok, %{status: 500, body: %{"message" => "boom"}}}
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "Unexpected response from GitHub API when resolving branch", fn ->
      Fetch.run(["--repo", repo, "--branch", branch, "--dest", dest])
    end
  end

  test "raises when a required file is missing at the selected commit", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    sha = "abc123"
    dest = Path.join(tmp_dir, "python")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      expected_prefix = "https://raw.githubusercontent.com/#{repo}/#{sha}/"

      if String.starts_with?(url, expected_prefix) do
        filename = String.replace_prefix(url, expected_prefix, "")

        if filename == "pipeline.py" do
          {:ok, %{status: 404, body: "not found"}}
        else
          {:ok, %{status: 200, body: "ok\n"}}
        end
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "File 'pipeline.py' not found at commit #{sha}", fn ->
      Fetch.run(["--repo", repo, "--commit", sha, "--dest", dest])
    end
  end

  test "raises when downloading a file fails with transport error", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    sha = "abc123"
    dest = Path.join(tmp_dir, "python")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      expected_prefix = "https://raw.githubusercontent.com/#{repo}/#{sha}/"

      if String.starts_with?(url, expected_prefix) do
        filename = String.replace_prefix(url, expected_prefix, "")

        if filename == "pdf_to_md.py" do
          {:error, :timeout}
        else
          {:ok, %{status: 200, body: "ok\n"}}
        end
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "Failed to download pdf_to_md.py: :timeout", fn ->
      Fetch.run(["--repo", repo, "--commit", sha, "--dest", dest])
    end
  end

  test "raises on unexpected response while downloading a file", %{tmp_dir: tmp_dir} do
    repo = "acme/crawler-ingest"
    sha = "abc123"
    dest = Path.join(tmp_dir, "python")

    Zaq.FetchPythonHTTPClientStub.put_responder(fn url, _opts ->
      expected_prefix = "https://raw.githubusercontent.com/#{repo}/#{sha}/"

      if String.starts_with?(url, expected_prefix) do
        filename = String.replace_prefix(url, expected_prefix, "")

        if filename == "clean_md.py" do
          {:ok, %{status: 500, body: "server error"}}
        else
          {:ok, %{status: 200, body: "ok\n"}}
        end
      else
        raise "unexpected url: #{url}"
      end
    end)

    assert_raise Mix.Error, "Unexpected response when downloading clean_md.py", fn ->
      Fetch.run(["--repo", repo, "--commit", sha, "--dest", dest])
    end
  end
end
