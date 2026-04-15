defmodule Zaq.Ingestion.Python.Steps.ImageToText do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  @doc """
  Tests the image-to-text pipeline by invoking the Python script with `--ping`.

  Returns `:ok` on success, `{:error, reason}` otherwise.
  """
  @spec ping() :: :ok | {:error, String.t()}
  def ping do
    cfg = Zaq.System.get_image_to_text_config()
    args = [api_key: cfg.api_key, endpoint: cfg.endpoint, model: cfg.model]

    case Runner.run("image_to_text.py", ["--ping"] ++ build_args(args)) do
      {:ok, _} -> :ok
      {:error, %{output: output}} -> {:error, output}
    end
  end

  def run(images_folder, output_json, opts) when is_list(opts) do
    Runner.run(
      "image_to_text.py",
      ["--folder", images_folder, "--output", output_json] ++ build_args(opts)
    )
  end

  def run(images_folder, output_json, api_key) when is_binary(api_key) do
    run(images_folder, output_json, api_key: api_key)
  end

  def run_single(image_path, output_json, opts) when is_list(opts) do
    Runner.run(
      "image_to_text.py",
      [image_path, "--output", output_json] ++ build_args(opts)
    )
  end

  def run_single(image_path, output_json, api_key) when is_binary(api_key) do
    run_single(image_path, output_json, api_key: api_key)
  end

  defp build_args(opts) do
    args = []
    args = if opts[:api_key], do: args ++ ["--api-key", opts[:api_key]], else: args
    args = if opts[:endpoint], do: args ++ ["--api-url", opts[:endpoint]], else: args
    args = if opts[:model], do: args ++ ["--model", opts[:model]], else: args
    args = if opts[:prompt], do: args ++ ["--prompt", opts[:prompt]], else: args
    args
  end
end
