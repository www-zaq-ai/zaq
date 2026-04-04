# Elixir Guidelines

## Elixir

- Elixir lists **do not support index-based access via the access syntax**.

  **Never do this (invalid)**:
  ```elixir
  i = 0
  mylist = ["blue", "green"]
  mylist[i]
  ```

  Instead, **always** use `Enum.at`, pattern matching, or `List`:
  ```elixir
  i = 0
  mylist = ["blue", "green"]
  Enum.at(mylist, i)
  ```

- Elixir variables are immutable but can be rebound. For block expressions like `if`, `case`, `cond`, you **must** bind the result to a variable:

  ```elixir
  # INVALID
  if connected?(socket) do
    socket = assign(socket, :val, val)
  end

  # VALID
  socket =
    if connected?(socket) do
      assign(socket, :val, val)
    end
  ```

- **Never** nest multiple modules in the same file — causes cyclic dependencies and compilation errors.
- **Never** use map access syntax (`changeset[:field]`) on structs. Access fields directly via `my_struct.field` or use higher-level APIs like `Ecto.Changeset.get_field/2`.
- Use the standard library for date/time: `Time`, `Date`, `DateTime`, `Calendar`. Never install additional dependencies unless asked (exception: `date_time_parser` for parsing).
- Don't use `String.to_atom/1` on user input — memory leak risk.
- Predicate function names should not start with `is_` and should end in `?`. Names like `is_thing` are reserved for guards.
- Elixir's built-in OTP primitives like `DynamicSupervisor` and `Registry` require names in the child spec:
  ```elixir
  {DynamicSupervisor, name: MyApp.MyDynamicSup}
  DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)
  ```
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. Pass `timeout: :infinity` in most cases.

---

## Mix

- Read the docs and options before using tasks: `mix help task_name`
- To debug test failures: `mix test test/my_test.exs` or `mix test --failed`
- `mix deps.clean --all` is **almost never needed** — avoid unless you have a strong reason.

---

## Tests

- **Always use `start_supervised!/1`** to start processes in tests — guarantees cleanup between tests.
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests.
- Instead of sleeping to wait for a process to finish, use `Process.monitor/1` and assert on the DOWN message:

  ```elixir
  ref = Process.monitor(pid)
  assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  ```

- Instead of sleeping to synchronize before the next call, use `_ = :sys.get_state/1` to ensure the process has handled prior messages.

---

## Ecto

- **Always** preload Ecto associations in queries when they'll be accessed in templates.
- Remember `import Ecto.Query` and other supporting modules when writing `seeds.exs`.
- `Ecto.Schema` fields always use `:string` type even for `:text` columns: `field :name, :string`.
- `Ecto.Changeset.validate_number/2` **does not support the `:allow_nil` option** — it's never needed.
- **Always** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields.
- Fields set programmatically (e.g. `user_id`) must not be listed in `cast` calls — set them explicitly.
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files.