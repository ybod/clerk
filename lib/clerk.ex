defmodule Clerk do
  @moduledoc """
  Global Module that can run schedulled jobs on one of the listed nodes

  Params:
    enabled: bool,
    execute_on_start: bool (default = false),
    execution_interval: integer,
    task_module: atom,
    init_args: term (default = nil),
    execution_timeout: integer (default = 5000)
  """

  use GenServer

  defstruct [:execution_interval, :task_module, :task_state, :execution_timeout]

  require Logger

  @task_interface [execute: 1, init: 1, nodes: 0]

  # spec
  def child_spec(%{task_module: module} = args) when is_atom(module) do
    unless valid_task_module?(module),
      do: raise(ArgumentError, message: "invalid task module #{get_short_name(module)}")

    %{
      id: Module.concat(Clerk, module),
      start: {Clerk, :start_link, [args]}
    }
  end

  # client

  def start_link(params) when is_map(params) do
    GenServer.start_link(__MODULE__, params)
  end

  # server

  @impl true
  def init(%{enabled: true, execution_interval: interval, task_module: module} = params) do
    # get initial task state from running init function with init arguments
    {:ok, task_state} = apply(module, :init, [Map.get(params, :init_args)])

    clerk_state = %__MODULE__{
      execution_interval: interval,
      task_module: module,
      task_state: task_state,
      execution_timeout: Map.get(params, :timeout, :timer.seconds(5))
    }

    case try_register_global_name({__MODULE__, module}) do
      {:ok, :registered} ->
        Logger.info(
          "Clerk: periodic taks registered on node #{Node.self()} for #{get_short_name(module)} with #{interval}ms" <>
            " execution interval"
        )

        if Map.get(params, :execute_on_start, false) do
          Process.send(self(), :execute_periodic_task, [])
        else
          Process.send_after(self(), :execute_periodic_task, interval)
        end

      {:error, :exists} ->
        Logger.info(
          "Clerk: monitoring periodic task from node #{Node.self()} for #{get_short_name(module)} with #{interval}ms" <>
            " interval"
        )

        Process.send_after(self(), :monitor_periodic_task, interval)
    end

    {:ok, clerk_state}
  end

  def init(%{enabled: false, task_module: module}) do
    Logger.info("Clerk: ignoring periodic task for #{get_short_name(module)}")
    :ignore
  end

  @impl true
  def handle_info(:execute_periodic_task, %__MODULE__{} = clerk_state) do
    {:ok, new_state} =
      execute_periodic_task(clerk_state.task_module, clerk_state.task_state, clerk_state.execution_timeout)

    Process.send_after(self(), :execute_periodic_task, clerk_state.execution_interval)

    {:noreply, %{clerk_state | task_state: new_state}}
  end

  def handle_info(:monitor_periodic_task, %__MODULE__{} = clerk_state) do
    case try_register_global_name({__MODULE__, clerk_state.task_module}) do
      {:ok, :registered} ->
        Logger.warn(
          "Clerk: new periodic taks registered on node #{Node.self()} for #{clerk_state.task_module} with" <>
            " #{clerk_state.execution_interval}ms execution interval"
        )

        Process.send(self(), :execute_periodic_task, [])

      {:error, :exists} ->
        Process.send_after(self(), :monitor_periodic_task, clerk_state.execution_interval)
    end

    {:noreply, clerk_state}
  end

  # helpers

  defp valid_task_module?(module) do
    Enum.all?(@task_interface, fn {function, arity} -> function_exported?(module, function, arity) end)
  end

  defp try_register_global_name({__MODULE__, _task_module} = global_name) do
    case :global.whereis_name(global_name) do
      :undefined ->
        case :global.register_name(global_name, self(), &resolve_name_clash/3) do
          :yes -> {:ok, :registered}
          :no -> {:error, :exists}
        end

      pid ->
        if pid != self(), do: {:error, :exists}, else: {:error, :self}
    end
  end

  defp execute_periodic_task(module, state, timeout) do
    random_node = Enum.random(Node.list([:visible, :this]))

    if random_node != Node.self() do
      :erpc.call(random_node, module, :execute, [state], timeout)
    else
      apply(module, :execute, [state])
    end
  end

  # resolve global name clash by selecting one node to register global name
  defp resolve_name_clash(name, pid1, pid2) do
    case :global.whereis_name(name) do
      ^pid1 -> pid1
      ^pid2 -> pid2
      :undefined -> if node(pid1) < node(pid2), do: pid1, else: pid2
      _ -> raise RuntimeError
    end
  end

  # Remove Elixir from module name for logging
  defp get_short_name(module) do
    Enum.intersperse(Module.split(module), ".")
  end
end
