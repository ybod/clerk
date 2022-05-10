defmodule Clerk do
  @moduledoc """
  Global Module that can run scheduled jobs on one of the listed nodes

  Params:
    enabled: bool / required,
    instant: bool / false,
    interval (ms): integer >= 500 or nil / required,
    task (module): atom / required,
    args: term / nil,
    timeout (ms): integer / 5000
  """

  use GenServer

  defstruct [:interval, :task, :state, :timeout]

  require Logger

  @task_callbacks [execute: 1, init: 1, nodes: 0]
  @default_timeout :timer.seconds(5)

  # spec
  def child_spec(%{task: task_module} = args) when is_atom(task_module) do
    unless valid_task_module?(task_module),
      do: raise(ArgumentError, message: "invalid task module #{get_short_name(task_module)}")

    %{
      id: clerk_task_id(task_module),
      start: {Clerk, :start_link, [args]}
    }
  end

  # client

  def start_link(%{task: task_module} = args) do
    GenServer.start_link(__MODULE__, args, name: clerk_task_id(task_module))
  end

  # server
  @impl true
  def init(%{enabled: true, task: task_module} = args) do
    task_interval = Map.get(args, :interval)
    task_timeout = Map.get(args, :timeout, @default_timeout)

    unless (is_integer(task_interval) and task_interval >= 0) or is_nil(task_interval),
      do: raise(ArgumentError, message: "invalid task interval #{inspect(task_interval)}")

    unless is_integer(task_timeout), do: raise(ArgumentError, message: "invalid task timeout #{inspect(task_timeout)}")

    # run init task callback and get initial state
    init_state =
      case task_module.init(Map.get(args, :args)) do
        :ok -> nil
        {:ok, res} -> res
      end

    clerk_state = %__MODULE__{
      interval: task_interval,
      task: task_module,
      state: init_state,
      timeout: task_timeout
    }

    case try_register_global_name({__MODULE__, task_module}) do
      {:registered, _} ->
        Logger.info("Clerk registered on node #{Node.self()} for task #{get_short_name(task_module)}")

        if Map.get(args, :instant, false), do: send(self(), :execute_instantly)

        # TODO: case with interval == 0
        if clerk_state.interval != nil do
          Logger.info("Clerk task #{get_short_name(task_module)} execution interval #{clerk_state.interval}")
          Process.send_after(self(), :execute_periodically, clerk_state.interval)
        else
          Logger.info("Clerk task #{get_short_name(task_module)} execution interval is nil")
        end

      {:exists, pid} ->
        Logger.info("Clerk monitoring task #{get_short_name(task_module)} from node #{Node.self()}")
        Process.monitor(pid)
    end

    {:ok, clerk_state}
  end

  def init(%{enabled: false, task: task_module}) do
    Logger.info("Clerk disabled for task #{get_short_name(task_module)}")
    :ignore
  end

  @impl true
  def handle_info(:execute_instantly, %__MODULE__{} = clerk_state) do
    clerk_state =
      case execute_task(clerk_state.task, clerk_state.state, clerk_state.timeout) do
        {:ok, new_task_state} -> %{clerk_state | state: new_task_state}
        :ok -> %{clerk_state | state: nil}
      end

    {:noreply, clerk_state}
  end

  @impl true
  def handle_info(:execute_periodically, %__MODULE__{} = clerk_state) do
    clerk_state =
      case execute_task(clerk_state.task, clerk_state.state, clerk_state.timeout) do
        {:ok, new_task_state} -> %{clerk_state | state: new_task_state}
        :ok -> %{clerk_state | state: nil}
      end

    Process.send_after(self(), :execute_periodically, clerk_state.interval)

    {:noreply, clerk_state}
  end

  def handle_info({:DOWN, _ref, :process, object, reason}, %__MODULE__{} = clerk_state) do
    Logger.warn("Clerk monitor on node #{Node.self()} recieved DOWN message from #{node(object)} with reason #{reason}")

    # TODO: do we need to log any task params here?
    case try_register_global_name({__MODULE__, clerk_state.task}) do
      {:registered, _} ->
        Logger.info("Clerk REregistered on node #{Node.self()} for task #{get_short_name(clerk_state.task)}")

        if clerk_state.interval != nil do
          Process.send_after(self(), :execute_periodically, clerk_state.interval)
        end

      {:exists, pid} ->
        Logger.info("Clerk monitoring from node #{Node.self()} for task #{get_short_name(clerk_state.task)}")
        Process.monitor(pid)
    end

    {:noreply, clerk_state}
  end

  # helpers

  defp valid_task_module?(module) do
    exported_functions = module.__info__(:functions)

    Enum.all?(@task_callbacks, fn {fun, ar} -> ar == Keyword.get(exported_functions, fun) end)
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

  defp execute_task(module, state, timeout) do
    random_node = Enum.random(module.nodes())

    if random_node != Node.self() do
      :erpc.call(random_node, module, :execute, [state], timeout)
    else
      module.execute(state)
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

  defp clerk_task_id(task_module), do: Module.concat(Clerk, task_module)

  # Remove Elixir from module name
  defp get_short_name(module) do
    Enum.intersperse(Module.split(module), ".")
  end
end
