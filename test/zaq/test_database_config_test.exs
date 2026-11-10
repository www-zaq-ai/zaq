defmodule Zaq.TestDatabaseConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tmp_dir
  @config Path.expand("../../config/test.exs", __DIR__)

  test "merge-queue refs fit without losing branch, E2E or partition isolation", context do
    branch = "gh-readonly-queue/main/pr-123-" <> String.duplicate("a", 40)
    other_branch = "gh-readonly-queue/main/pr-123-" <> String.duplicate("b", 40)

    cases = [
      {branch, false, ""},
      {branch, false, ""},
      {other_branch, false, ""},
      {branch, true, ""},
      {branch, false, "retrieval_eval_native"},
      {branch, false, "retrieval_eval_parade"}
    ]

    [first, repeated | others] = databases(context, cases)
    assert first == repeated
    assert length(Enum.uniq([first | others])) == 5
    assert Enum.all?([first | others], &(byte_size(&1) <= 63))
    assert String.starts_with?(first, "zaq_test_gh_readonly_queue_")
    assert Enum.at(others, 1) =~ "zaq_test_e2e_"
    assert String.ends_with?(Enum.at(others, 2), "retrieval_eval_native")
    assert String.ends_with?(Enum.at(others, 3), "retrieval_eval_parade")
  end

  test "short names and exact-limit names stay unchanged", context do
    branch = String.duplicate("a", 54)
    e2e_branch = String.duplicate("a", 49)

    assert databases(context, [
             {"feature/Short-branch", false, ""},
             {nil, false, ""},
             {branch, false, ""},
             {e2e_branch, true, "1"}
           ]) == [
             "zaq_test_feature_short_branch",
             "zaq_test_",
             "zaq_test_" <> branch,
             "zaq_test_e2e_" <> e2e_branch <> "1"
           ]
  end

  test "an oversized partition fails explicitly rather than truncating identifiers", context do
    [result] = databases(context, [{String.duplicate("a", 80), true, String.duplicate("1", 40)}])
    assert {:error, message} = result
    assert message =~ "MIX_TEST_PARTITION"
  end

  property "generated branch names fit and preserve suffixes deterministically", context do
    check all(
            branches <- list_of(string(:alphanumeric, min_length: 1, max_length: 180), length: 8),
            partition <- string(:alphanumeric, max_length: 24),
            e2e? <- boolean(),
            max_runs: 10
          ) do
      cases = Enum.map(branches, &{&1, e2e?, partition})
      names = databases(context, cases ++ cases)
      {first, repeated} = Enum.split(names, length(cases))

      assert first == repeated

      for name <- first do
        assert byte_size(name) <= 63
        assert String.starts_with?(name, if(e2e?, do: "zaq_test_e2e_", else: "zaq_test_"))
        assert String.ends_with?(name, partition)
      end
    end
  end

  defp databases(%{tmp_dir: tmp_dir}, cases) do
    # Read the real configuration in a child VM and disposable Git repo. No
    # environment variables or branches are changed in the running test suite.
    script = """
    System.cmd("git", ["init", "--quiet"])
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com",
      "commit", "--quiet", "--allow-empty", "-m", "fixture"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    results = for {branch, e2e?, partition} <- #{inspect(cases, limit: :infinity)} do
      if branch do
        {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/" <> branch])
      else
        {_, 0} = System.cmd("git", ["update-ref", "--no-deref", "HEAD", String.trim(commit)])
      end
      System.put_env("E2E", if(e2e?, do: "1", else: "0"))
      System.put_env("MIX_TEST_PARTITION", partition)
      try do
        Config.Reader.read!(#{inspect(@config)}, env: :test, target: :host)
        |> Keyword.fetch!(:zaq)
        |> Keyword.fetch!(Zaq.Repo)
        |> Keyword.fetch!(:database)
      rescue
        error -> {:error, Exception.message(error)}
      end
    end
    IO.puts(Base.encode64(:erlang.term_to_binary(results)))
    """

    {output, status} =
      System.cmd("elixir", ["-e", script],
        cd: tmp_dir,
        env: [{"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    output
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end
end
