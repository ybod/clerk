defmodule ClerkTest do
  @moduledoc false

  use ExUnit.Case, async: false
  doctest Clerk

  alias ClerkTest.TestTask
  alias ClerkTest.TestCluster

  setup_all do
    {:module, _} = Code.ensure_loaded(TestTask)
    :ok
  end

  describe "locally" do
    test "will not start if not enabled" do
      assert :ignore = Clerk.start_link(%{enabled: false, task_module: TestTask, execution_interval: 60_000})
    end

    test "when started supervised can execute task immediately on local node" do
      start_supervised!(
        {Clerk,
         %{
           enabled: true,
           execute_on_start: true,
           execution_interval: 60_000,
           task_module: TestTask,
           init_args: %{caller: self()}
         }}
      )

      local_node = node()

      assert_receive({:executed, ^local_node, _execution_interval})
    end

    test "when started supervised can execute periodic task after given interval on local node" do
      start_supervised!(
        {Clerk,
         %{
           enabled: true,
           execute_on_start: false,
           execution_interval: 100,
           task_module: TestTask,
           init_args: %{caller: self(), task_start_time: System.monotonic_time()}
         }}
      )

      assert_receive({:executed, _node, execution_interval}, 200)
      assert execution_interval >= 100
      assert_receive({:executed, _node, execution_interval}, 200)
      assert execution_interval >= 100
      assert_receive({:executed, _node, execution_interval}, 200)
      assert execution_interval >= 100
    end
  end

  describe "in cluster" do
    setup do
      master = TestCluster.init()

      on_exit(fn -> TestCluster.teardown() end)

      {:ok, master_node: master}
    end

    test "task will be executed on differend nodes", %{master_node: master_node} do
      [slave_node1, slave_node2, slave_node3] = TestCluster.spawn_slaves(3)

      TestCluster.load_test_jobs([slave_node1, slave_node2, slave_node3])

      start_supervised!(
        {Clerk,
         %{
           enabled: true,
           execute_on_start: false,
           execution_interval: 50,
           task_module: TestTask,
           init_args: %{caller: self()}
         }}
      )

      # task executed on every available node at least once
      assert executed_on_node(master_node)
      assert executed_on_node(slave_node1)
      assert executed_on_node(slave_node2)
      assert executed_on_node(slave_node3)

      TestCluster.kill_slaves([slave_node1, slave_node2, slave_node3])
    end

    test "clerk can survive nodes crash", %{master_node: master_node} do
      [slave_node1, slave_node2] = TestCluster.spawn_slaves(2)
      TestCluster.load_test_jobs([slave_node1, slave_node2])

      params = %{
        enabled: true,
        execute_on_start: false,
        execution_interval: 50,
        task_module: TestTask,
        init_args: %{caller: self()}
      }

      TestCluster.start_jobs_scheduler([slave_node1, slave_node2], params)

      start_supervised!({Clerk, params})

      assert_receive({:executed, exec_node1, _exec_interval})
      assert_receive({:executed, exec_node2, _exec_interval})
      assert_receive({:executed, exec_node3, _exec_interval})

      assert exec_node1 in [master_node, slave_node1, slave_node2]
      assert exec_node2 in [master_node, slave_node1, slave_node2]
      assert exec_node3 in [master_node, slave_node1, slave_node2]

      TestCluster.kill_slaves([slave_node2])

      :empty = flush_test_job_messages()

      assert_receive({:executed, exec_node1, _exec_interval})
      assert_receive({:executed, exec_node2, _exec_interval})
      assert_receive({:executed, exec_node3, _exec_interval})

      assert exec_node1 in [master_node, slave_node1]
      assert exec_node2 in [master_node, slave_node1]
      assert exec_node3 in [master_node, slave_node1]

      TestCluster.kill_slaves([slave_node1])

      :empty = flush_test_job_messages()

      assert_receive({:executed, ^master_node, _exec_interval})
      assert_receive({:executed, ^master_node, _exec_interval})
      assert_receive({:executed, ^master_node, _exec_interval})

      # task executes locally even if there is no distibuted nodes available
      :ok = Node.stop()

      :empty = flush_test_job_messages()

      local = node()
      assert_receive({:executed, ^local, _exec_interval})
    end

    test "can restart on another node", %{master_node: master_node} do
      [slave_node1, slave_node2, slave_node3] = TestCluster.spawn_slaves(3)
      TestCluster.load_test_jobs([slave_node1, slave_node2, slave_node3])

      params = %{
        enabled: true,
        execute_on_start: false,
        execution_interval: 50,
        task_module: TestTask,
        init_args: %{caller: self()}
      }

      TestCluster.start_jobs_scheduler([slave_node1], params)

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node1, slave_node2, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node1, slave_node2, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node1, slave_node2, slave_node3]

      TestCluster.start_jobs_scheduler([slave_node2], params)
      TestCluster.kill_slaves([slave_node1])

      :empty = flush_test_job_messages()

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node2, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node2, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node2, slave_node3]

      TestCluster.start_jobs_scheduler([slave_node3], params)
      TestCluster.kill_slaves([slave_node2])

      :empty = flush_test_job_messages()

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node3]

      assert_receive({:executed, exec_node, _exec_interval})
      assert exec_node in [master_node, slave_node3]

      TestCluster.kill_slaves([slave_node3])
      :empty = flush_test_job_messages()

      start_supervised!({Clerk, params})
      assert_receive({:executed, ^master_node, _exec_interval})
      assert_receive({:executed, ^master_node, _exec_interval})
      assert_receive({:executed, ^master_node, _exec_interval})
    end
  end

  defp executed_on_node(desired_node) when is_atom(desired_node) do
    assert_receive({:executed, execution_node, _execution_interval})

    if execution_node == desired_node do
      true
    else
      executed_on_node(desired_node)
    end
  end

  defp flush_test_job_messages() do
    receive do
      {:executed, _, _} -> flush_test_job_messages()
    after
      0 -> :empty
    end
  end
end
