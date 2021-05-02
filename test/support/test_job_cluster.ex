defmodule ClerkTest.TestCluster do
  @moduledoc """
  Helpers for running tests in distibuted environment
  """

  alias ClerkTest.TestTask

  def init() do
    {:ok, _pid} = :net_kernel.start([:master@localhost, :shortnames])

    :master@localhost
  end

  def teardown(), do: :net_kernel.stop()

  def spawn_slaves(number) when number > 0 do
    for n <- 1..number, {:ok, node} = :slave.start_link(:localhost, 'slave#{n}'), do: node
  end

  def kill_slaves(nodes) when is_list(nodes) do
    Enum.each(nodes, &:slave.stop(&1))
  end

  def load_test_jobs(slave_nodes) when is_list(slave_nodes) do
    {module, binary, filename} = :code.get_object_code(TestTask)

    Enum.each(slave_nodes, fn node ->
      :rpc.block_call(node, :code, :add_paths, [:code.get_path()])
      :rpc.block_call(node, :code, :load_binary, [module, filename, binary])
    end)
  end

  def start_jobs_scheduler(slave_nodes, params) when is_list(slave_nodes) and is_map(params) do
    {module, binary, filename} = :code.get_object_code(Clerk)

    Enum.each(slave_nodes, fn node ->
      :rpc.block_call(node, :code, :add_paths, [:code.get_path()])
      :rpc.block_call(node, :code, :load_binary, [module, filename, binary])

      :rpc.block_call(node, Supervisor, :start_link, [
        [{Clerk, params}],
        [strategy: :one_for_one]
      ])
    end)
  end
end
