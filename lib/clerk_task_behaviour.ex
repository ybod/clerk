defmodule Clerk.TaskBehaviour do
  @moduledoc """
  Clerk Periodic Task interface functions
  """
  @callback init(params :: any()) :: {:ok, state :: any()}

  @callback execute(state :: any()) :: {:ok, state :: any()}

  @callback nodes() :: [] | [node()]
end
