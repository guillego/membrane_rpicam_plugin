defmodule Membrane.Rpicam.Source do
  @moduledoc """
  Membrane Source Element for capturing live feed from a RasperryPi camera using rpicam-apps based on libcamera
  """

  use Membrane.Source
  alias Membrane.{Buffer, H264, RemoteStream}
  require Membrane.Logger

  @app_name "libcamera-vid"
  @max_retries 3

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :bytestream, content_format: H264},
    flow_control: :push

  def_options timeout: [
                spec: Membrane.Time.non_neg() | :infinity,
                default: :infinity,
                description: """
                Time for which program runs in milliseconds.
                """
              ],
              framerate: [
                spec: {pos_integer(), pos_integer()} | :camera_default,
                default: :camera_default,
                description: """
                Fixed framerate.
                """
              ],
              width: [
                spec: pos_integer() | :camera_default,
                default: :camera_default,
                description: """
                Output image width.
                """
              ],
              height: [
                spec: pos_integer() | :camera_default,
                default: :camera_default,
                description: """
                Output image height.
                """
              ],
              camera_open_delay: [
                spec: Membrane.Time.non_neg(),
                default: Membrane.Time.milliseconds(50),
                inspector: &Membrane.Time.pretty_duration/1,
                description: """
                Determines for how long initial opening the camera should be delayed.
                No delay can cause a crash on Nerves system when initalizing the
                element during the boot sequence of the device.
                """
              ],
              bitrate: [
                spec: pos_integer() | :camera_default,
                default: :camera_default,
                description: """
                Set the target bitrate for the H.264 encoder, in bits per second. Only applies when encoding in H.264 format.
                """
              ],
              libav_audio: [
                spec: boolean(),
                default: false,
                description: """
                Set this option to enable audio encoding together with the video stream. When audio encoding is enabled, an output format that supports audio (e.g. mpegts, mkv, mp4) must be used.
                """
              ]

  @impl true
  def handle_init(_ctx, options) do
    Process.sleep(Membrane.Time.as_milliseconds(options.camera_open_delay, :round))

    state = %{
      app_port: open_port(options),
      init_time: nil,
      camera_open: false,
      retries: 0,
      options: options
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %RemoteStream{type: :bytestream, content_format: H264}}], state}
  end

  @impl true
  def handle_info({port, {:data, data}}, _ctx, %{app_port: port} = state) do
    time = Membrane.Time.monotonic_time()
    init_time = state.init_time || time

    buffer = %Buffer{payload: data, pts: time - init_time}

    {[buffer: {:output, buffer}], %{state | init_time: init_time, camera_open: true}}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_status}}, _ctx, %{app_port: port} = state) do
    cond do
      exit_status == 0 ->
        {[end_of_stream: :output], state}

      state.camera_open ->
        raise "#{@app_name} error, exit status: #{exit_status}"

      state.retries < @max_retries ->
        Membrane.Logger.warning("Camera failed to open with exit status #{exit_status}, retrying")
        Process.sleep(50)
        new_port = open_port(state.options)
        {[], %{state | retries: state.retries + 1, app_port: new_port}}

      true ->
        raise "Max retries exceeded, camera failed to open, exit status: #{exit_status}"
    end
  end

  @spec open_port(Membrane.Rpicam.Source.t()) :: port()
  defp open_port(options) do
    Port.open({:spawn, create_command(options)}, [:binary, :exit_status])
  end

  @spec create_command(Membrane.Element.options()) :: String.t()
  defp create_command(opts) do
    timeout =
      case opts.timeout do
        :infinity -> 0
        t when t >= 0 -> t
      end

    {framerate_num, framerate_denom} = resolve_defaultable_option(opts.framerate, {-1, 1})
    framerate_float = framerate_num / framerate_denom

    width = resolve_defaultable_option(opts.width, 0)
    height = resolve_defaultable_option(opts.height, 0)
    bitrate = resolve_defaultable_option(opts.bitrate, 0)
    libav_audio = bool_to_integer(opts.libav_audio)


    "#{@app_name} -t #{timeout} --framerate #{framerate_float} --width #{width} --height #{height} --bitrate #{bitrate} --libav_audio #{libav_audio} -o -"
  end

  @spec resolve_defaultable_option(:camera_default | x, x) :: x when x: var
  defp resolve_defaultable_option(option, default) do
    case option do
      :camera_default -> default
      x -> x
    end
  end

  @spec bool_to_integer(boolean()) :: integer()
  defp bool_to_integer(true), do: 1
  defp bool_to_integer(false), do: 0

end
