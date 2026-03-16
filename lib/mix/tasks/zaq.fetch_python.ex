defmodule Mix.Tasks.Zaq.Python.Fetch do
  @moduledoc """
  Fetches the python crawler scripts from the upstream repository.

  ## Usage

      mix zaq.python.fetch [options]

  ## Options

      * `--branch <name>` - The branch name to fetch from (default: "main")
      * `--commit <sha>` - The specific commit SHA to fetch (overrides --branch)
      * `--dest <path>` - The destination directory (default: "priv/python/crawler-ingest")
      * `--repo <url>` - The GitHub repository (default: "www-zaq-ai/crawler-ingest")
  """
  use Mix.Task

  require Logger

  @default_repo "www-zaq-ai/crawler-ingest"
  @default_branch "main"
  @default_dest "priv/python/crawler-ingest"
  @required_files ~w(
    web_crawler.py
    pipeline.py
    pdf_to_md.py
    docx_to_md.py
    xlsx_to_md.py
    image_dedup.py
    image_to_text.py
    clean_md.py
    inject_descriptions.py
    requirements.txt
  )

  @doc false
  def required_files, do: @required_files

  @impl Mix.Task
  def run(args) do
    ensure_http_client_started()

    {opts, _} =
      OptionParser.parse!(args,
        strict: [branch: :string, commit: :string, dest: :string, repo: :string]
      )

    repo = opts[:repo] || @default_repo
    dest = opts[:dest] || @default_dest

    # Determine commit SHA
    commit_sha =
      if opts[:commit] do
        opts[:commit]
      else
        branch = opts[:branch] || @default_branch
        resolve_branch_sha(repo, branch)
      end

    if is_nil(commit_sha) do
      Mix.raise("Could not resolve commit SHA for the given reference.")
    end

    Mix.shell().info([:green, "Fetching scripts from #{repo} @ #{commit_sha}..."])

    # Ensure destination exists
    File.mkdir_p!(dest)

    # Fetch files
    Enum.each(@required_files, fn filename ->
      fetch_file(repo, commit_sha, filename, dest)
    end)

    # Write manifest
    manifest = %{
      repo: repo,
      commit: commit_sha,
      files: @required_files,
      fetched_at: DateTime.utc_now()
    }

    File.write!(Path.join(dest, "manifest.json"), Jason.encode!(manifest, pretty: true))

    Mix.shell().info([:green, "✓ Successfully fetched python scripts to #{dest}"])

    Mix.shell().info([
      :yellow,
      "Don't forget to install the requirements inside a virtual environment:"
    ])

    Mix.shell().info([:yellow, "  python3 -m venv .venv"])
    Mix.shell().info([:yellow, "  source .venv/bin/activate"])
    Mix.shell().info([:yellow, "  pip install -r #{dest}/requirements.txt"])
  end

  defp ensure_http_client_started do
    if http_client() == Req do
      case Application.ensure_all_started(:req) do
        {:ok, _started_apps} ->
          :ok

        {:error, {app, reason}} ->
          Mix.raise("Failed to start #{inspect(app)} required for Req: #{inspect(reason)}")

        {:error, reason} ->
          Mix.raise("Failed to start Req dependencies: #{inspect(reason)}")
      end
    end
  end

  defp resolve_branch_sha(repo, branch) do
    url = "https://api.github.com/repos/#{repo}/commits/#{branch}"

    case http_client().get(url, headers: [{"User-Agent", "Mix Task"}]) do
      {:ok, %{status: 200, body: %{"sha" => sha}}} ->
        sha

      {:ok, %{status: 404}} ->
        Mix.raise("Branch '#{branch}' not found in repository '#{repo}'")

      {:error, reason} ->
        Mix.raise("Failed to resolve branch SHA: #{inspect(reason)}")

      _ ->
        Mix.raise("Unexpected response from GitHub API when resolving branch")
    end
  end

  defp fetch_file(repo, sha, filename, dest) do
    url = "https://raw.githubusercontent.com/#{repo}/#{sha}/#{filename}"
    dest_path = Path.join(dest, filename)

    Mix.shell().info("  Downloading #{filename}...")

    case http_client().get(url) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(dest_path, body)

        if String.ends_with?(filename, ".py") do
          File.chmod(dest_path, 0o755)
        end

      {:ok, %{status: 404}} ->
        Mix.raise("File '#{filename}' not found at commit #{sha}")

      {:error, reason} ->
        Mix.raise("Failed to download #{filename}: #{inspect(reason)}")

      _ ->
        Mix.raise("Unexpected response when downloading #{filename}")
    end
  end

  defp http_client do
    Application.get_env(:zaq, :http_client, Req)
  end
end
