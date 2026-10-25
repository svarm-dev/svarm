defmodule Svarm.Settings.Catalog do
  @moduledoc """
  Closed catalog types for one settings revision.

  A revision is a full snapshot: profiles, boards, and bindings. Callers pass
  string-keyed maps. This module parses those maps and does not write the
  database. Unknown keys are ignored. Values never become atoms.
  """

  @enforce_keys [:providers, :harnesses, :toolchains, :boards, :bindings]
  defstruct [:providers, :harnesses, :toolchains, :boards, :bindings]

  @type id :: String.t()

  @type provider :: %{
          id: id(),
          name: String.t(),
          kind: String.t(),
          endpoint: String.t() | nil,
          credential_id: String.t() | nil,
          default_model: String.t()
        }

  @type harness :: %{
          id: id(),
          name: String.t(),
          adapter: String.t(),
          provider_id: id(),
          command: [String.t()],
          env: %{optional(String.t()) => String.t()},
          default_toolchain_id: id() | nil
        }

  @type toolchain :: %{
          id: id(),
          name: String.t(),
          source: map()
        }

  @type board :: %{
          id: id(),
          name: String.t(),
          tracker: map(),
          remote: map(),
          enabled: boolean(),
          max_concurrent: pos_integer() | nil,
          verification: map() | nil,
          first_run_at: DateTime.t() | nil
        }

  @type binding :: %{
          board_id: id(),
          harness_id: id(),
          model_override: String.t() | nil,
          credential_id: String.t() | nil,
          toolchain_id: id() | nil
        }

  @type t :: %__MODULE__{
          providers: [provider()],
          harnesses: [harness()],
          toolchains: [toolchain()],
          boards: [board()],
          bindings: [binding()]
        }

  @type error ::
          :invalid_catalog
          | :invalid_id
          | :invalid_name
          | :invalid_adapter
          | :invalid_toolchain_source
          | :invalid_verification
          | :invalid_timestamp
          | :duplicate_id
          | :unknown_provider
          | :unknown_harness
          | :unknown_toolchain
          | :unknown_board

  @adapters %{"cli" => "cli", "pi_rpc" => "pi_rpc"}

  @doc """
  Parse one revision body. Does not assign a revision number.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, error()}
  def parse(attrs) when is_map(attrs) do
    with {:ok, providers} <- parse_list(attrs, "providers", &parse_provider/1),
         {:ok, harnesses} <- parse_list(attrs, "harnesses", &parse_harness/1),
         {:ok, toolchains} <- parse_list(attrs, "toolchains", &parse_toolchain/1),
         {:ok, boards} <- parse_list(attrs, "boards", &parse_board/1),
         {:ok, bindings} <- parse_list(attrs, "bindings", &parse_binding/1) do
      {:ok,
       %__MODULE__{
         providers: providers,
         harnesses: harnesses,
         toolchains: toolchains,
         boards: boards,
         bindings: bindings
       }}
    end
  end

  def parse(_), do: {:error, :invalid_catalog}

  @doc """
  Referenced profiles and boards must exist in the same revision snapshot.
  """
  @spec validate_references(t()) :: :ok | {:error, error()}
  def validate_references(%__MODULE__{} = catalog) do
    provider_ids = ids(catalog.providers)
    harness_ids = ids(catalog.harnesses)
    toolchain_ids = ids(catalog.toolchains)
    board_ids = ids(catalog.boards)

    with :ok <- unique_ids(catalog.providers),
         :ok <- unique_ids(catalog.harnesses),
         :ok <- unique_ids(catalog.toolchains),
         :ok <- unique_ids(catalog.boards),
         :ok <- unique_binding_boards(catalog.bindings),
         :ok <- harness_refs(catalog.harnesses, provider_ids, toolchain_ids) do
      binding_refs(catalog.bindings, board_ids, harness_ids, toolchain_ids)
    end
  end

  @doc "Plain map for callers. Nested tracker, remote, env, source, and verification stay string-keyed."
  @spec to_map(pos_integer(), DateTime.t(), t()) :: map()
  def to_map(revision, %DateTime{} = inserted_at, %__MODULE__{} = catalog)
      when is_integer(revision) and revision > 0 do
    %{
      revision: revision,
      inserted_at: inserted_at,
      providers: catalog.providers,
      harnesses: catalog.harnesses,
      toolchains: catalog.toolchains,
      boards: catalog.boards,
      bindings: catalog.bindings
    }
  end

  defp parse_list(attrs, key, parser) do
    case fetch(attrs, key) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        reduce_parsed(list, parser)

      {:ok, _} ->
        {:error, :invalid_catalog}
    end
  end

  defp reduce_parsed(list, parser) do
    list
    |> Enum.reduce_while({:ok, []}, &accumulate_parsed(&1, &2, parser))
    |> reverse_parsed()
  end

  defp accumulate_parsed(item, {:ok, acc}, parser) do
    case parser.(item) do
      {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp reverse_parsed({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_parsed({:error, _} = err), do: err

  defp parse_provider(attrs) when is_map(attrs) do
    with {:ok, id} <- id_field(attrs, "id"),
         {:ok, name} <- name_field(attrs),
         {:ok, kind} <- name_field(attrs, "kind"),
         {:ok, endpoint} <- optional_string(attrs, "endpoint"),
         {:ok, credential_id} <- optional_id(attrs, "credential_id"),
         {:ok, default_model} <- name_field(attrs, "default_model") do
      {:ok,
       %{
         id: id,
         name: name,
         kind: kind,
         endpoint: endpoint,
         credential_id: credential_id,
         default_model: default_model
       }}
    end
  end

  defp parse_provider(_), do: {:error, :invalid_catalog}

  defp parse_harness(attrs) when is_map(attrs) do
    with {:ok, id} <- id_field(attrs, "id"),
         {:ok, name} <- name_field(attrs),
         {:ok, adapter} <- adapter_field(attrs),
         {:ok, provider_id} <- id_field(attrs, "provider_id"),
         {:ok, command} <- command_field(attrs),
         {:ok, env} <- env_field(attrs),
         {:ok, default_toolchain_id} <- optional_id(attrs, "default_toolchain_id") do
      {:ok,
       %{
         id: id,
         name: name,
         adapter: adapter,
         provider_id: provider_id,
         command: command,
         env: env,
         default_toolchain_id: default_toolchain_id
       }}
    end
  end

  defp parse_harness(_), do: {:error, :invalid_catalog}

  defp parse_toolchain(attrs) when is_map(attrs) do
    with {:ok, id} <- id_field(attrs, "id"),
         {:ok, name} <- name_field(attrs),
         {:ok, source} <- source_field(attrs) do
      {:ok, %{id: id, name: name, source: source}}
    end
  end

  defp parse_toolchain(_), do: {:error, :invalid_catalog}

  defp parse_board(attrs) when is_map(attrs) do
    with {:ok, id} <- id_field(attrs, "id"),
         {:ok, name} <- name_field(attrs),
         {:ok, tracker} <- string_map(attrs, "tracker"),
         {:ok, remote} <- string_map(attrs, "remote"),
         {:ok, enabled} <- enabled_field(attrs),
         {:ok, max_concurrent} <- optional_pos(attrs, "max_concurrent"),
         {:ok, verification} <- verification_field(attrs),
         {:ok, first_run_at} <- optional_datetime(attrs, "first_run_at") do
      {:ok,
       %{
         id: id,
         name: name,
         tracker: tracker,
         remote: remote,
         enabled: enabled,
         max_concurrent: max_concurrent,
         verification: verification,
         first_run_at: first_run_at
       }}
    end
  end

  defp parse_board(_), do: {:error, :invalid_catalog}

  defp parse_binding(attrs) when is_map(attrs) do
    with {:ok, board_id} <- id_field(attrs, "board_id"),
         {:ok, harness_id} <- id_field(attrs, "harness_id"),
         {:ok, model_override} <- optional_string(attrs, "model_override"),
         {:ok, credential_id} <- optional_id(attrs, "credential_id"),
         {:ok, toolchain_id} <- optional_id(attrs, "toolchain_id") do
      {:ok,
       %{
         board_id: board_id,
         harness_id: harness_id,
         model_override: model_override,
         credential_id: credential_id,
         toolchain_id: toolchain_id
       }}
    end
  end

  defp parse_binding(_), do: {:error, :invalid_catalog}

  defp adapter_field(attrs) do
    case fetch(attrs, "adapter") do
      {:ok, value} ->
        case Map.get(@adapters, to_string_if_atom(value)) do
          nil -> {:error, :invalid_adapter}
          adapter -> {:ok, adapter}
        end

      :error ->
        {:error, :invalid_adapter}
    end
  end

  defp command_field(attrs) do
    case fetch(attrs, "command") do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &nonempty_string?/1), do: {:ok, list}, else: {:error, :invalid_catalog}

      {:ok, _} ->
        {:error, :invalid_catalog}
    end
  end

  defp env_field(attrs) do
    case fetch(attrs, "env") do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, map} when is_map(map) -> string_pairs(map)
      {:ok, _} -> {:error, :invalid_catalog}
    end
  end

  defp source_field(attrs) do
    case fetch(attrs, "source") do
      {:ok, source} when is_map(source) -> parse_source(source)
      _ -> {:error, :invalid_toolchain_source}
    end
  end

  defp parse_source(source) do
    case fetch(source, "type") do
      {:ok, "mise"} -> mise_source(source)
      {:ok, "repository_mise"} -> repository_source(source)
      {:ok, "path"} -> path_source(source)
      _ -> {:error, :invalid_toolchain_source}
    end
  end

  defp mise_source(source) do
    with {:ok, pins} <- fetch(source, "pins"),
         true <- is_list(pins) and pins != [],
         {:ok, parsed} <- parse_pins(pins) do
      {:ok, %{"type" => "mise", "pins" => parsed}}
    else
      _ -> {:error, :invalid_toolchain_source}
    end
  end

  defp parse_pins(pins) do
    Enum.reduce_while(pins, {:ok, []}, fn pin, {:ok, acc} ->
      case parse_pin(pin) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_pin(pin) when is_map(pin) do
    with {:ok, name} <- name_field(pin, "name"),
         {:ok, version} <- name_field(pin, "version") do
      {:ok, %{"name" => name, "version" => version}}
    else
      _ -> {:error, :invalid_toolchain_source}
    end
  end

  defp parse_pin(_), do: {:error, :invalid_toolchain_source}

  defp repository_source(source) do
    with {:ok, trust} <- fetch(source, "trust"),
         true <- is_map(trust),
         {:ok, path} <- name_field(trust, "path"),
         {:ok, sha256} <- sha256_field(trust),
         {:ok, trusted_by} <- name_field(trust, "trusted_by"),
         {:ok, trusted_at} <- iso8601_field(trust, "trusted_at") do
      {:ok,
       %{
         "type" => "repository_mise",
         "trust" => %{
           "path" => path,
           "sha256" => sha256,
           "trusted_by" => trusted_by,
           "trusted_at" => trusted_at
         }
       }}
    else
      _ -> {:error, :invalid_toolchain_source}
    end
  end

  defp path_source(source) do
    case fetch(source, "requirements") do
      {:ok, reqs} when is_list(reqs) and reqs != [] ->
        if Enum.all?(reqs, &nonempty_string?/1) do
          {:ok, %{"type" => "path", "requirements" => reqs}}
        else
          {:error, :invalid_toolchain_source}
        end

      _ ->
        {:error, :invalid_toolchain_source}
    end
  end

  defp verification_field(attrs) do
    case fetch(attrs, "verification") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, map} when is_map(map) -> parse_verification(map)
      {:ok, _} -> {:error, :invalid_verification}
    end
  end

  defp parse_verification(map) do
    with {:ok, executable} <- name_field(map, "executable"),
         {:ok, args} <- command_list(map, "args"),
         {:ok, timeout_ms} <- pos_field(map, "timeout_ms") do
      {:ok, %{"executable" => executable, "args" => args, "timeout_ms" => timeout_ms}}
    else
      _ -> {:error, :invalid_verification}
    end
  end

  defp command_list(map, key) do
    case fetch(map, key) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &nonempty_string?/1),
          do: {:ok, list},
          else: {:error, :invalid_verification}

      _ ->
        {:error, :invalid_verification}
    end
  end

  defp enabled_field(attrs) do
    case fetch(attrs, "enabled") do
      :error -> {:ok, false}
      {:ok, nil} -> {:ok, false}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _} -> {:error, :invalid_catalog}
    end
  end

  defp string_map(attrs, key) do
    case fetch(attrs, key) do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, map} when is_map(map) -> string_pairs(map)
      {:ok, _} -> {:error, :invalid_catalog}
    end
  end

  defp string_pairs(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        nonempty_string?(key) and is_binary(value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        is_atom(key) and nonempty_string?(Atom.to_string(key)) and is_binary(value) ->
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

        true ->
          {:halt, {:error, :invalid_catalog}}
      end
    end)
  end

  defp optional_datetime(attrs, key) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, %DateTime{} = dt} -> {:ok, DateTime.truncate(dt, :second)}
      {:ok, value} when is_binary(value) -> parse_datetime(value)
      {:ok, _} -> {:error, :invalid_timestamp}
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp iso8601_field(map, key) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> {:ok, DateTime.to_iso8601(DateTime.truncate(dt, :second))}
          _ -> {:error, :invalid_toolchain_source}
        end

      _ ->
        {:error, :invalid_toolchain_source}
    end
  end

  defp sha256_field(map) do
    case fetch(map, "sha256") do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/^[0-9a-f]{64}$/, value),
          do: {:ok, value},
          else: {:error, :invalid_toolchain_source}

      _ ->
        {:error, :invalid_toolchain_source}
    end
  end

  defp id_field(attrs, key) do
    case fetch(attrs, key) do
      {:ok, value} ->
        if valid_id?(value), do: {:ok, value}, else: {:error, :invalid_id}

      :error ->
        {:error, :invalid_id}
    end
  end

  defp optional_id(attrs, key) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, ""} -> {:ok, nil}
      {:ok, value} -> if valid_id?(value), do: {:ok, value}, else: {:error, :invalid_id}
    end
  end

  defp name_field(attrs, key \\ "name") do
    case fetch(attrs, key) do
      {:ok, value} ->
        if nonempty_string?(value), do: {:ok, value}, else: {:error, :invalid_name}

      :error ->
        {:error, :invalid_name}
    end
  end

  defp optional_string(attrs, key) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, ""} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _} -> {:error, :invalid_catalog}
    end
  end

  defp optional_pos(attrs, key) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _} -> {:error, :invalid_catalog}
    end
  end

  defp pos_field(map, key) do
    case fetch(map, key) do
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, :invalid_verification}
    end
  end

  defp valid_id?(value) when is_binary(value) do
    String.trim(value) != "" and byte_size(value) <= 200 and not String.contains?(value, <<0>>)
  end

  defp valid_id?(_), do: false

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_), do: false

  defp fetch(map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, existing_atom(key)) -> {:ok, Map.get(map, existing_atom(key))}
      true -> :error
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp to_string_if_atom(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp to_string_if_atom(value), do: value

  defp ids(items), do: MapSet.new(items, & &1.id)

  defp unique_ids(items) do
    ids = Enum.map(items, & &1.id)
    if ids == Enum.uniq(ids), do: :ok, else: {:error, :duplicate_id}
  end

  defp unique_binding_boards(bindings) do
    ids = Enum.map(bindings, & &1.board_id)
    if ids == Enum.uniq(ids), do: :ok, else: {:error, :duplicate_id}
  end

  defp harness_refs(harnesses, provider_ids, toolchain_ids) do
    Enum.reduce_while(harnesses, :ok, fn harness, :ok ->
      cond do
        not MapSet.member?(provider_ids, harness.provider_id) ->
          {:halt, {:error, :unknown_provider}}

        harness.default_toolchain_id &&
            not MapSet.member?(toolchain_ids, harness.default_toolchain_id) ->
          {:halt, {:error, :unknown_toolchain}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp binding_refs(bindings, board_ids, harness_ids, toolchain_ids) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      cond do
        not MapSet.member?(board_ids, binding.board_id) ->
          {:halt, {:error, :unknown_board}}

        not MapSet.member?(harness_ids, binding.harness_id) ->
          {:halt, {:error, :unknown_harness}}

        binding.toolchain_id && not MapSet.member?(toolchain_ids, binding.toolchain_id) ->
          {:halt, {:error, :unknown_toolchain}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
