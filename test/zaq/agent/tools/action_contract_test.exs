defmodule Zaq.Agent.Tools.ActionContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.General.EncodeBase64
  alias Zaq.Agent.Tools.Registry

  defmodule NimbleAction do
    use Jido.Action,
      name: "contract_nimble",
      schema: [
        mode: [type: {:in, [:fast, :slow]}, default: :fast],
        count: [type: :integer, default: 1],
        probe: [type: :any]
      ]

    @impl Jido.Action
    def run(params, _context) do
      if is_pid(params[:probe]), do: send(params.probe, {:ran, __MODULE__})
      {:ok, %{mode: params.mode, count: params.count}}
    end
  end

  defmodule ZoiAction do
    use Jido.Action,
      name: "contract_zoi",
      schema:
        Zoi.object(%{
          mode: Zoi.enum([:fast, :slow]) |> Zoi.default(:fast),
          label: Zoi.string(),
          probe: Zoi.any() |> Zoi.optional()
        })

    @impl Jido.Action
    def run(params, _context) do
      if is_pid(params[:probe]), do: send(params.probe, {:ran, __MODULE__})
      {:ok, %{mode: params.mode, label: params.label}}
    end
  end

  defmodule JsonSchemaAction do
    use Jido.Action,
      name: "contract_json_schema",
      schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string"},
          "retries" => %{"type" => "integer"}
        },
        "required" => ["message"]
      }

    @impl Jido.Action
    def run(params, _context), do: {:ok, params}
  end

  defmodule NotAnAction do
    def schema, do: []
  end

  describe "validate/2 (never executes)" do
    test "does not run the action for Nimble, Zoi or JSON Schema actions" do
      assert {:ok, %{mode: :slow, count: 3}} =
               ActionContract.validate(NimbleAction, %{
                 "mode" => "slow",
                 "count" => "3",
                 "probe" => self()
               })

      assert {:ok, %{mode: :fast, label: "x"}} =
               ActionContract.validate(ZoiAction, %{"label" => "x", "probe" => self()})

      assert {:ok, %{message: "hi", retries: 2}} =
               ActionContract.validate(JsonSchemaAction, %{"message" => "hi", "retries" => 2})

      refute_received {:ran, _}
    end

    test "rehydrates atom enums for Nimble and Zoi schemas from JSON strings" do
      assert {:ok, %{mode: :slow}} = ActionContract.validate(NimbleAction, %{"mode" => "slow"})

      assert {:ok, %{mode: :slow}} =
               ActionContract.validate(ZoiAction, %{"label" => "a", "mode" => "slow"})
    end

    test "keeps an invalid enum string so the action's own validation rejects it" do
      assert {:error, _} = ActionContract.validate(NimbleAction, %{"mode" => "warp"})
      assert {:error, _} = ActionContract.validate(ZoiAction, %{"label" => "a", "mode" => "warp"})
    end

    test "returns validation errors instead of raising" do
      assert {:error, _} = ActionContract.validate(ZoiAction, %{})
      assert {:error, _} = ActionContract.validate(ZoiAction, %{"label" => 123})
      assert {:error, _} = ActionContract.validate(NimbleAction, %{"count" => "many"})
    end

    test "applies Zoi and Nimble defaults" do
      assert {:ok, %{mode: :fast, count: 1}} = ActionContract.validate(NimbleAction, %{})
      assert {:ok, %{mode: :fast}} = ActionContract.validate(ZoiAction, %{"label" => "a"})
    end

    test "preserves unknown keys and never creates atoms for them" do
      unknown = "zaq_790_contract_unknown_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      assert {:ok, %{:label => "a", ^unknown => "v"}} =
               ActionContract.validate(ZoiAction, %{"label" => "a", unknown => "v"})

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "returns invalid_action for unloadable modules and modules without validate_params/1" do
      missing = Zaq.Agent.Tools.ActionContractTest.DoesNotExist

      assert {:error, {:invalid_action, ^missing, _}} = ActionContract.validate(missing, %{})

      assert {:error, {:invalid_action, NotAnAction, :missing_validate_params}} =
               ActionContract.validate(NotAnAction, %{})
    end
  end

  describe "normalize/2" do
    property "normalization is idempotent for bounded external parameters" do
      value =
        one_of([
          integer(-10..10),
          string(:alphanumeric, max_length: 12),
          member_of([:fast, :slow, nil])
        ])

      check all(
              action <- member_of([NimbleAction, ZoiAction, JsonSchemaAction]),
              pairs <-
                list_of(
                  tuple(
                    {member_of([
                       "mode",
                       :mode,
                       "count",
                       :count,
                       "label",
                       :label,
                       "message",
                       :message,
                       "extra"
                     ]), value}
                  ),
                  max_length: 5
                ),
              max_runs: 100
            ) do
        params = Map.new(pairs)
        assert {:ok, normalized} = ActionContract.normalize(action, params)
        assert {:ok, ^normalized} = ActionContract.normalize(action, normalized)
      end
    end

    property "supported atom enums survive a JSON round trip" do
      check all(
              action <- member_of([NimbleAction, ZoiAction]),
              mode <- member_of([:fast, :slow]),
              max_runs: 100
            ) do
        params =
          if action == NimbleAction,
            do: %{mode: mode, count: 2},
            else: %{mode: mode, label: "example"}

        decoded = params |> Jason.encode!() |> Jason.decode!()
        assert {:ok, %{mode: ^mode} = normalized} = ActionContract.normalize(action, params)
        assert {:ok, ^normalized} = ActionContract.normalize(action, decoded)
        assert {:ok, ^normalized} = ActionContract.validate(action, decoded)
      end
    end

    property "unknown string keys survive normalization without creating atoms" do
      check all(
              suffix <- string(:alphanumeric, min_length: 1, max_length: 20),
              value <- one_of([integer(-10..10), string(:alphanumeric, max_length: 12)]),
              action <- member_of([NimbleAction, ZoiAction, JsonSchemaAction]),
              max_runs: 100
            ) do
        key = "zaq_790_property_unknown_#{suffix}"
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

        known =
          if action == JsonSchemaAction, do: %{"message" => "example"}, else: %{"mode" => "other"}

        assert {:ok, normalized} = ActionContract.normalize(action, Map.put(known, key, value))
        assert normalized[key] == value
        assert Map.has_key?(normalized, if(action == JsonSchemaAction, do: :message, else: :mode))
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end
    end

    test "converts string keys for known keys only" do
      assert {:ok, %{count: 2, extra: _}} =
               ActionContract.normalize(NimbleAction, %{"count" => 2, extra: 1})
    end

    test "leaves non-enum, non-atom and unrelated values untouched" do
      assert {:ok, %{1 => "one"}} = ActionContract.normalize(NimbleAction, %{1 => "one"})
      assert {:ok, %{mode: :slow}} = ActionContract.normalize(NimbleAction, %{mode: :slow})
    end

    test "returns invalid_action for an unloadable module" do
      missing = Zaq.Agent.Tools.ActionContractTest.AlsoMissing
      assert {:error, {:invalid_action, ^missing, _}} = ActionContract.normalize(missing, %{})
    end
  end

  describe "execute/4 (Jido.Exec owns execution)" do
    test "runs the action with normalized, validated params" do
      assert {:ok, %{mode: :slow, count: 2}} =
               ActionContract.execute(NimbleAction, %{
                 "mode" => "slow",
                 "count" => 2,
                 "probe" => self()
               })

      assert_received {:ran, NimbleAction}

      assert {:ok, %{mode: :slow, label: "z"}} =
               ActionContract.execute(ZoiAction, %{
                 "mode" => "slow",
                 "label" => "z",
                 "probe" => self()
               })

      assert_received {:ran, ZoiAction}
    end

    test "returns validation errors without running the action" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               ActionContract.execute(ZoiAction, %{"probe" => self()})

      refute_received {:ran, _}
    end

    test "applies schema defaults from string-keyed params for a registered Zoi action" do
      assert {:ok, %{encoded: "aGVsbG8="}} =
               ActionContract.execute(EncodeBase64, %{"data" => "hello"})
    end
  end

  test "the contract does not widen the Registry allowlist" do
    keys = Registry.keys()
    refute Enum.any?([NimbleAction, ZoiAction, JsonSchemaAction], &(&1.name() in keys))
    assert Enum.all?(Registry.tools(), &is_atom(&1.module))
    assert length(keys) == length(Enum.uniq(keys))
  end
end
