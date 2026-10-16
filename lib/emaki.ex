defmodule Emaki do
  @moduledoc """
  Official Elixir SDK for [emaki](https://emaki.ai): generate Seedance 2.5 and
  Seedance 2.0 clips, and images, with the API key of your emaki account.

      {:ok, url} = Emaki.generate_video("a paper lantern drifting down a night river")
      {:ok, img} = Emaki.generate_image("a ramen stall in the rain, neon reflections")
      {:ok, left} = Emaki.credits()

  Pass `api_key:` or set `EMAKI_API_KEY`; create a key at
  https://emaki.ai/settings/apikeys.

  Failures are `{:error, reason, message}` where `reason` is `:auth`, `:quota`,
  `:plan`, `:busy`, `:rejected`, `:validation`, `:failed`, `:timeout` or `:other`.

  Uses only `:httpc` from OTP and the standard `JSON` module; no dependencies.
  """

  @base "https://emaki.ai"
  @keys_url "https://emaki.ai/settings/apikeys"
  @video_model "seedance_2_5"
  @image_model "nano_banana_2_lite"

  @type reason ::
          :auth | :quota | :plan | :busy | :rejected | :validation | :failed | :timeout | :other
  @type error :: {:error, reason(), String.t()}

  @doc """
  Generates one clip and returns the URL of the finished MP4.

  `params` is passed through as the request's `parameters`, e.g.
  `%{"duration" => 8, "resolution" => "720p", "aspect_ratio" => "9:16", "image" => url}`.

  Options: `:model` (default `"seedance_2_5"`), `:api_key`, `:poll_ms` (5000),
  `:timeout_ms` (15 minutes), `:base_url`.
  """
  @spec generate_video(String.t(), map(), keyword()) :: {:ok, String.t()} | error()
  def generate_video(prompt, params \\ %{}, opts \\ []) do
    {params, opts} = split(params, opts)

    with {:ok, id} <- submit(prompt, opts[:model] || @video_model, params, opts),
         do: wait(id, opts)
  end

  @doc """
  Generates one image and returns its URL. Default model `"nano_banana_2_lite"`.
  Same `params` and options as `generate_video/3`.
  """
  @spec generate_image(String.t(), map(), keyword()) :: {:ok, String.t()} | error()
  def generate_image(prompt, params \\ %{}, opts \\ []) do
    {params, opts} = split(params, opts)

    with {:ok, id} <- submit(prompt, opts[:model] || @image_model, params, opts),
         do: wait(id, opts)
  end

  # generate_video("...", api_key: "sk-...") puts options where params go.
  defp split(params, opts) when is_list(params), do: {%{}, params ++ opts}
  defp split(params, opts), do: {params, opts}

  @doc "Submits a run and returns its id without waiting."
  @spec submit(String.t(), String.t(), map(), keyword()) :: {:ok, String.t()} | error()
  def submit(prompt, model \\ @video_model, params \\ %{}, opts \\ []) do
    if not is_binary(prompt) or String.trim(prompt) == "" do
      {:error, :validation, "emaki: prompt is required"}
    else
      body = %{"prompt" => prompt, "model" => model}
      body = if params == %{} or params == nil, do: body, else: Map.put(body, "parameters", params)

      case call("/api/video/ai", body, opts) do
        {:ok, %{"data" => %{"id" => id}}} -> {:ok, id}
        {:ok, _} -> {:error, :other, "emaki: the service returned no id"}
        err -> err
      end
    end
  end

  @doc """
  Returns the run's record: a map with `"id"`, `"status"` (`"generating"`,
  `"completed"` or `"failed"`), `"videoUrl"` (images too) and `"failureCode"`.
  """
  @spec status(String.t(), keyword()) :: {:ok, map()} | error()
  def status(id, opts \\ []) do
    case call("/api/video/status", %{"videoId" => id}, opts) do
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, :other, "emaki: unreadable status"}
      err -> err
    end
  end

  @doc "Remaining credits on the account. Free to call."
  @spec credits(keyword()) :: {:ok, integer()} | error()
  def credits(opts \\ []) do
    case call("/api/user/get-user-credits", %{}, opts) do
      {:ok, %{"code" => 0, "data" => %{"remainingCredits" => n}}} ->
        {:ok, n}

      # This endpoint answers refusals with HTTP 200 and code -1.
      {:ok, env} ->
        msg = to_string(env["message"] || "request refused")
        {:error, if(String.contains?(String.downcase(msg), "api key"), do: :auth, else: :other), "emaki: " <> msg}

      err ->
        err
    end
  end

  @doc "Polls a submitted run until it completes, fails or the deadline passes."
  @spec wait(String.t(), keyword()) :: {:ok, String.t()} | error()
  def wait(id, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + (opts[:timeout_ms] || 900_000)
    poll(id, opts[:poll_ms] || 5_000, deadline, opts)
  end

  defp poll(id, every, deadline, opts) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout, "emaki: deadline passed; the run may still finish in your emaki library"}
    else
      Process.sleep(every)

      case status(id, opts) do
        {:ok, %{"status" => "completed", "videoUrl" => url}} when is_binary(url) ->
          {:ok, url}

        {:ok, %{"status" => "failed"} = d} ->
          {:error, :failed, "emaki: the run failed (#{d["failureCode"] || "unknown"})"}

        {:error, :auth, _} = err ->
          err

        # a dropped poll is not a failed run
        _ ->
          poll(id, every, deadline, opts)
      end
    end
  end

  @doc "Maps an HTTP status and error body to the reason that says what to do next."
  @spec classify(integer(), term()) :: reason()
  def classify(status, body) do
    code = if is_map(body), do: body["code"]

    cond do
      status == 401 -> :auth
      status == 402 -> :quota
      status == 403 -> :plan
      status == 409 -> :busy
      code in ["content_cooldown", "content_blocked"] -> :rejected
      status == 400 -> :validation
      true -> :other
    end
  end

  defp call(path, body, opts) do
    key = opts[:api_key] || System.get_env("EMAKI_API_KEY")
    transport = opts[:transport] || (&http/3)

    if key in [nil, ""] do
      {:error, :auth, "emaki: an API key is required; create one at #{@keys_url}"}
    else
      case transport.((opts[:base_url] || @base) <> path, body, key) do
        {:ok, status, data} when status in 200..299 and is_map(data) ->
          {:ok, data}

        {:ok, status, data} ->
          msg = if is_map(data), do: data["error"] || data["message"], else: nil
          {:error, classify(status, data), "emaki: " <> to_string(msg || "HTTP #{status}")}

        {:error, why} ->
          {:error, :other, "emaki: " <> inspect(why)}
      end
    end
  end

  @doc false
  def http(url, body, key) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> key)},
      {~c"user-agent", ~c"emaki-elixir/0.1.0"}
    ]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)}

    case :httpc.request(:post, request, [timeout: 60_000, ssl: ssl], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp}} ->
        data =
          case JSON.decode(resp) do
            {:ok, d} -> d
            _ -> nil
          end

        {:ok, status, data}

      {:error, why} ->
        {:error, why}
    end
  end
end
