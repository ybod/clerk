defmodule ClerkTest do
  @moduledoc false

  use ExUnit.Case, async: false
  doctest Clerk

  import ExUnit.CaptureLog

  alias ClerkTest.TestTask
  alias ClerkTest.TestCluster

  setup_all do
    {:module, _} = Code.ensure_loaded(TestTask)
    :ok
  end

  describe "locally" do
    test "will not start if not enabled" do
      log_info =
        capture_log(fn ->
          :ignore = Clerk.start_link(%{enabled: false, task_module: TestTask, execution_interval: 60_000})
        end)

      assert log_info =~ "Clerk: ignoring periodic task for ClerkTest.TestTask"
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
end
