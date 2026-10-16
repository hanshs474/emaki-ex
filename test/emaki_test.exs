defmodule EmakiTest do
  use ExUnit.Case

  # Replays recorded response shapes in order and reports each request body.
  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    me = self()

    fn url, body, _key ->
      send(me, {:req, url, body})
      Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
    end
  end

  defp opts(t), do: [api_key: "sk-x", poll_ms: 0, transport: t]

  test "video: submit, poll, return videoUrl" do
    t =
      script([
        {:ok, 200, %{"success" => true, "data" => %{"id" => "v1", "status" => "generating"}}},
        {:ok, 200, %{"success" => true, "data" => %{"id" => "v1", "status" => "generating"}}},
        {:ok, 200, %{"success" => true, "data" => %{"id" => "v1", "status" => "completed", "videoUrl" => "https://cdn.emaki.ai/v1.mp4"}}}
      ])

    assert {:ok, "https://cdn.emaki.ai/v1.mp4"} = Emaki.generate_video("a fox", %{"duration" => 6}, opts(t))
    assert_received {:req, "https://emaki.ai/api/video/ai", %{"model" => "seedance_2_5", "parameters" => %{"duration" => 6}}}
    assert_received {:req, "https://emaki.ai/api/video/status", %{"videoId" => "v1"}}
  end

  test "image: default model, keyword opts in place of params" do
    t =
      script([
        {:ok, 200, %{"success" => true, "data" => %{"id" => "i1", "status" => "generating"}}},
        {:ok, 200, %{"success" => true, "data" => %{"id" => "i1", "status" => "completed", "videoUrl" => "https://cdn.emaki.ai/i1.png"}}}
      ])

    assert {:ok, "https://cdn.emaki.ai/i1.png"} = Emaki.generate_image("a mug", opts(t))
    assert_received {:req, _, body}
    assert body == %{"prompt" => "a mug", "model" => "nano_banana_2_lite"}
  end

  test "failed run carries failureCode" do
    t =
      script([
        {:ok, 200, %{"success" => true, "data" => %{"id" => "f1", "status" => "generating"}}},
        {:ok, 200, %{"success" => true, "data" => %{"id" => "f1", "status" => "failed", "failureCode" => "provider_error"}}}
      ])

    assert {:error, :failed, msg} = Emaki.generate_video("x", %{}, opts(t))
    assert msg =~ "provider_error"
  end

  test "submit errors map to reasons" do
    for {status, body, reason} <- [
          {401, %{"error" => "Invalid API key. Create one at https://emaki.ai/settings/apikeys"}, :auth},
          {402, %{"error" => "Insufficient credits"}, :quota},
          {403, %{"error" => "This model requires a purchase"}, :plan},
          {409, %{"error" => "Video generation is already in progress"}, :busy},
          {429, %{"error" => "cooling down", "code" => "content_cooldown"}, :rejected},
          {400, %{"error" => "blocked", "code" => "content_blocked"}, :rejected},
          {400, %{"error" => "Missing required parameters: prompt and model"}, :validation},
          {500, %{"error" => "Internal error"}, :other}
        ] do
      t = script([{:ok, status, body}])
      assert {:error, ^reason, _} = Emaki.submit("x", "seedance_2_5", %{}, opts(t))
    end
  end

  test "credits" do
    t = script([{:ok, 200, %{"code" => 0, "message" => "ok", "data" => %{"remainingCredits" => 42, "hasPurchasedCredits" => false}}}])
    assert {:ok, 42} = Emaki.credits(opts(t))
    t = script([{:ok, 200, %{"code" => -1, "message" => "Invalid API key. Create one at https://emaki.ai/settings/apikeys"}}])
    assert {:error, :auth, _} = Emaki.credits(opts(t))
  end

  @tag :live
  test "live: credits with the real key, auth error with a wrong key" do
    assert {:ok, n} = Emaki.credits()
    assert is_integer(n)
    assert {:error, :auth, _} = Emaki.submit("live check", "nano_banana_2_lite", %{}, api_key: "sk-wrong-key")
  end
end
