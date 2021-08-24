defmodule Clerk do
  @moduledoc """
  Global Module that can run schedulled jobs on one of the listed nodes

  Params:
    enabled: bool,
    execute_on_start: bool (default = false),
    chain_with: list (default: [])
    execution_interval: integer,
    task_module: atom,
    init_args: term (default = nil),
    execution_timeout: integer (default = 5000)
  """

  use GenServer

  defstruct [:execution_interval, :task_module, :task_state, :execution_timeout, :chain_with]

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
  def init(%{enabled: true, task_module: module} = params) do
    # get initial task state from running init function with init arguments
    {:ok, task_state} = apply(module, :init, [Map.get(params, :init_args)])

    # TODO: validate that chain_with contains valid Tasks
    clerk_state = %__MODULE__{
      execution_interval: Map.get(params, :execution_interval),
      task_module: module,
      task_state: task_state,
      execution_timeout: Map.get(params, :timeout, :timer.seconds(5)),
      chain_with: Map.get(params, :chain_with, [])
    }

    case try_register_global_name({__MODULE__, module}) do
      {:registered, _} ->
        Logger.info("Clerk registered on node #{Node.self()} for task #{get_short_name(module)}")

        unless clerk_state.execution_interval == nil,
          do: Logger.info("Clerk task #{get_short_name(module)} execution interval #{clerk_state.execution_interval}")

        unless clerk_state.chain_with == [],
          do: Logger.info("Clerk task #{get_short_name(module)} is chained with #{inspect(clerk_state.chain_with)}")

        cond do
          Map.get(params, :execute_on_start, false) == true ->
            Process.send(self(), :execute_periodic_task, [])

          clerk_state.execution_interval != nil ->
            Process.send_after(self(), :execute_periodic_task, clerk_state.execution_interval)

          true ->
            :noop
        end

      {:exists, pid} ->
        Logger.info("Clerk monitoring task #{get_short_name(module)} from node #{Node.self()}")

        Process.monitor(pid)
    end

    {:ok, clerk_state}
  end

  def init(%{enabled: false, task_module: module}) do
    Logger.info("Clerk ignoring task #{get_short_name(module)}")
    :ignore
  end

  @impl true
  def handle_info(:execute_periodic_task, %__MODULE__{} = clerk_state) do
    {:ok, new_state} =
      execute_periodic_task(clerk_state.task_module, clerk_state.task_state, clerk_state.execution_timeout)

    # send execution commands to all chained tasks
    Enum.each(clerk_state.chain_with, fn chained_task ->
      global_pid = :global.whereis_name({__MODULE__, chained_task})
      Process.send(global_pid, :execute_chained_task, [])
    end)

    Process.send_after(self(), :execute_periodic_task, clerk_state.execution_interval)

    {:noreply, %{clerk_state | task_state: new_state}}
  end

  def handle_info(:execute_chained_task, %__MODULE__{} = clerk_state) do
    {:ok, new_state} =
      execute_periodic_task(clerk_state.task_module, clerk_state.task_state, clerk_state.execution_timeout)

    # send execution commands to all chained tasks
    Enum.each(clerk_state.chain_with, fn chained_task ->
      global_pid = :global.whereis_name({__MODULE__, chained_task})
      Process.send(global_pid, :execute_chained_task, [])
    end)

    {:noreply, %{clerk_state | task_state: new_state}}
  end

  def handle_info({:DOWN, _ref, :process, object, reason}, %__MODULE__{} = clerk_state) do
    Logger.warn("Clerk monitor on node #{Node.self()} recieved DOWN message from #{node(object)} with reason #{reason}")

    # TODO: do we need to log all task details again (execution_interval and chain_with)?
    case try_register_global_name({__MODULE__, clerk_state.task_module}) do
      {:registered, _} ->
        Logger.info("Clerk REregistered on node #{Node.self()} for task #{get_short_name(clerk_state.task_module)}")

        if clerk_state.execution_interval != nil do
          Process.send_after(self(), :execute_periodic_task, clerk_state.execution_interval)
        end

      {:exists, pid} ->
        Logger.info("Clerk monitoring task #{get_short_name(clerk_state.task_module)} from node #{Node.self()}")

        Process.monitor(pid)
    end

    {:noreply, clerk_state}
  end

  # helpers

  defp valid_task_module?(module) do
    exported_functions = module.__info__(:functions)

    Enum.all?(@task_interface, &Enum.member?(exported_functions, &1))
  rescue
    UndefinedFunctionError -> false
  end

  defp try_register_global_name({__MODULE__, _task_module} = global_name) do
    case :global.whereis_name(global_name) do
      :undefined ->
        case :global.register_name(global_name, self(), &resolve_name_clash/3) do
          :yes -> {:registered, self()}
          :no -> {:exists, :global.whereis_name(global_name)}
        end

      pid when pid != self() ->
        {:exists, pid}
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
    end
  end

  # Remove Elixir from module name for logging
  defp get_short_name(module) do
    Enum.intersperse(Module.split(module), ".")
  end
end
