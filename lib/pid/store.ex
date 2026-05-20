defmodule Pid.Store do
  @moduledoc false

  @db __MODULE__

  def child_spec(_opts) do
    data_dir = Application.fetch_env!(:pid, :store)[:data_dir]
    Supervisor.child_spec({CubDB, [data_dir: data_dir, name: @db]}, id: __MODULE__)
  end

  def get(key, default \\ nil), do: CubDB.get(@db, key, default)

  def put(key, value), do: CubDB.put(@db, key, value)
end
