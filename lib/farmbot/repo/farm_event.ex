defmodule Farmbot.Repo.FarmEvent do
  @moduledoc """
  FarmEvent's are events that happen on a schedule.
  When it is time for the event to execute one of several things may happen:

      * A Regimen gets started.
      * A Sequence will execute.
  """

  @on_load :load_nif

  def load_nif do
    require Logger
    nif_file = '#{:code.priv_dir(:farmbot)}/build_calendar'
    case :erlang.load_nif(nif_file, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> Logger.warn "Failed to load nif: #{inspect reason}"
    end
  end

  alias Farmbot.Repo.JSONType

  use Ecto.Schema
  import Ecto.Changeset
  use Farmbot.Logger

  schema "farm_events" do
    field(:start_time, :string)
    field(:end_time, :string)
    field(:repeat, :integer)
    field(:time_unit, :string)
    field(:executable_type, Farmbot.Repo.ModuleType.FarmEvent)
    field(:executable_id, :integer)
    field(:calendar, JSONType)
  end

  use Farmbot.Repo.Syncable

  @required_fields [
    :id,
    :start_time,
    :end_time,
    :repeat,
    :time_unit,
    :executable_type,
    :executable_id
  ]

  def changeset(farm_event, params \\ %{}) do
    farm_event
    |> build_calendar
    |> cast(params, @required_fields ++ [:calendar])
    |> validate_required(@required_fields)
    |> unique_constraint(:id)
  end

  def bench do
    begin = :os.system_time(:seconds)
    res = Farmbot.HTTP.get!("/api/farm_events").body
    |> Poison.decode!(as: [%__MODULE__{}])
    |> Enum.map(&build_calendar(&1))

    IO.puts "total: #{:os.system_time(:seconds) - begin}"
    res
  end

  @compile {:inline, [build_calendar: 1]}
  def build_calendar(%__MODULE__{calendar: nil} = fe), do: fe
  def build_calendar(%__MODULE__{calendar: calendar} = fe)  when is_list(calendar) do
    current_time_seconds = :os.system_time(:second)
    start_time_seconds = DateTime.from_iso8601(fe.start_time) |> elem(1) |> DateTime.to_unix(:second)
    end_time_seconds = DateTime.from_iso8601(fe.end_time) |> elem(1) |> DateTime.to_unix(:second)
    repeat = fe.repeat
    repeat_frequency_seconds = time_unit_to_seconds(repeat, fe.time_unit)

    new_calendar =
      do_build_calendar(current_time_seconds,
                        start_time_seconds,
                        end_time_seconds,
                        repeat,
                        repeat_frequency_seconds)
                        |> Enum.map(&DateTime.from_unix!(&1))
                        |> Enum.map(&DateTime.to_iso8601(&1))
    %{fe | calendar: new_calendar}
  end

  # This should be replaced. YOU WILL KNOW if not.
  def do_build_calendar(now_seconds, start_time_seconds, end_time_seconds, repeat, repeat_frequency_seconds) do
    Logger.error 1, "Using (very) slow calendar builder!"
    grace_period_cutoff_seconds = now_seconds - 60
      Range.new(start_time_seconds, end_time_seconds)
      |> Enum.take_every(repeat * repeat_frequency_seconds)
      |> Enum.filter(&Kernel.>(&1, grace_period_cutoff_seconds))
      |> Enum.take(60)
      |> Enum.map(&Kernel.-(&1, div(&1, 60)))
  end

  @compile {:inline, [time_unit_to_seconds: 2]}
  defp time_unit_to_seconds(_, "never"), do: 0
  defp time_unit_to_seconds(repeat, "minutely"), do: 60 * repeat
  defp time_unit_to_seconds(repeat, "hourly"), do: 60 * 60 * repeat
  defp time_unit_to_seconds(repeat, "daily"), do: 60 * 60 * 24 * repeat
  defp time_unit_to_seconds(repeat, "weekly"), do: 60 * 60 * 24 * 7 * repeat
  defp time_unit_to_seconds(repeat, "monthly"), do: 60 * 60 * 24 * 30 * repeat
  defp time_unit_to_seconds(repeat, "yearly"), do: 60 * 60 * 24 * 365 * repeat
end
