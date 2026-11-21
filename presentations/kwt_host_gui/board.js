"use strict";

window.kwtBoard = (() => {
  // 便携版默认保持离线。只有从本机网关启动时显示连接入口。
  const enabled = location.protocol === "http:" && location.hostname === "127.0.0.1"
    && new URLSearchParams(location.search).get("board") === "1";

  async function request(action, payload) {
    const response = await fetch(`/api/board/${action}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const value = await response.json();
    if (!response.ok) throw new Error(value.error || "J8 网关无响应");
    return value;
  }

  return {
    enabled,
    connect: () => request("connect", {}),
    run: sampleId => request("run", { sample_id: sampleId }),
  };
})();
