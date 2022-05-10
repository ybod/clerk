# Clerk

Simple manager for global periodic tasks

This library can be used to run periodic tasks on multiple similar Erlang nodes, given that task will be executed only once on one randomly selected node with given interval.

For example, if You need to poll data from 3rd party API or update materialized view every 5 seconds but You application can dynamically scale from one  node to tens or hundreds of nodes running simultaneously and back time. Clerk will start a global manager process on one of the nodes that will run periodic task. Other nodes will monitor this global process process and will take control in case a node or process will shut down. Task will run on the randomly selected node to balance the load. This library does not use any centralized or distributed storage to sync execution between nodes, so there is no 100% guarantee that the execution will strictly adhere to the specified interval. The idea of this library is based on simplicity of usage and implementation.

To use this library You will need to define "task" module implementing 3 callbacks required by clerk task behaviour:

1) `execute/1` is required to define  task code that will be excuted. 

2) `init/1` is predefined callback that can do some setup, get, or define some initial task state using provided args. 

3) `list/0` is predefined callback that will return the list of te nodes that can be used to execute task. These nodes should have task module defined and loaded.

(1) and (2) callbacks should return either `:ok` or `{:ok, state}` tupples. `state` returned from the task execution will be passed to the next task call. Just keep in mind that this state is managed by the global process and it can be lost. Task should be able to recreate this state from the `init/1` call.


## Examples

Defining task module `some_periodic_task.ex`

```elixir
defmodule TestApp.PeriodicTask do
  use Clerk.Task

  @impl true
  def execute(%{http_client: http_client} = state) do

    do_some_api_call(http_client)

    {:ok, state}
  end
end
```

Configure task parameters from the application supervisor `application.ex`

```elixir
defmodule TestApp.Application do
  use Application

  def start(_type, _args) do
    # add app version into Logger meta
    :logger.update_primary_config(%{metadata: %{ver: @version}})

    children = [
      # Start the Ecto repository
      ForzaChallenge.Repo,
      # Periodic tasks
      {Clerk, api_poll_task_params()}
    ]

    opts = [strategy: :one_for_one, name: ForzaChallenge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp env(), do: Application.fetch_env!(:test_app, :env)

  defp api_poll_task_params() do
    %{
      enabled: env() != :test,
      task: TestApp.PeriodicTask,
      # do not run task on app start
      instant: false,
      args: %{http_client: TestApp.HttpClient},
      interval: 10_000,
      timeout: 30_000
    }
  end
end
```



## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `clerk` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:clerk, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/clerk](https://hexdocs.pm/clerk).

## Testing

Testing over local distributed nodes cluster requires **epmd** daemon to be running. You can start **epmd** via `epmd -daemon` command and stop with `epmd -kill`.