"use strict";

const elements = Object.fromEntries(Array.from(document.querySelectorAll("[id]"), node => [node.id, node]));
const { samples, audioRoot } = window.kwtDataset;
const replay = window.kwtReplay;
const board = window.kwtBoard;

let selection = null;
let playing = false;
let switchingMode = false;
let runCount = 0;
let boardSession = null;

function refreshControls() {
  const busy = playing || switchingMode;
  for (const key of ["draw", "select", "sample-number", "board-switch"]) elements[key].disabled = busy;
  elements.play.disabled = busy || !selection;
}

function showStatus(message, isError = false) {
  elements["sample-state"].textContent = message;
  elements["sample-state"].classList.toggle("alert", isError);
}

function clearResult(message) {
  elements.prediction.textContent = "—";
  elements.prediction.className = "prediction waiting";
  elements.meaning.classList.remove("board-output");
  elements.meaning.textContent = message;
  elements.truth.textContent = "—";
  elements.verdict.hidden = true;
}

function selectSample(index) {
  if (playing) return;
  if (!Number.isInteger(index) || index < 0 || index >= samples.length) {
    showStatus("请输入 000–599", true);
    return;
  }

  const id = String(index).padStart(3, "0");
  const sample = samples[index];
  selection = { id, sample };
  elements["sample-id"].textContent = `#${id}`;
  elements["sample-number"].value = id;
  elements.duration.textContent = `${sample.duration.toFixed(2)} s`;
  elements.waveform.setAttribute("aria-label", `样本 ${id} 的语音波形`);
  refreshControls();
  showStatus(boardSession ? "等待下发" : "等待播放");
  clearResult(boardSession ? "下发后显示板端回执" : "播放后揭晓");
  clearBoardMetrics();
  replay.renderWave(elements.waveform, sample.peaks);
}

function addRecord(id, prediction, truth, matches, source) {
  const row = document.createElement("tr");
  for (const value of [`#${id}`, prediction, truth, source, matches ? "一致" : "不一致"]) {
    const cell = document.createElement("td");
    cell.textContent = value;
    row.append(cell);
  }
  row.lastElementChild.className = matches ? "match" : "mismatch";
  elements["record-rows"].prepend(row);
  elements["record-table"].hidden = false;
  elements["empty-record"].hidden = true;
  runCount += 1;
  elements["record-count"].textContent = `${runCount} 次`;
}

function reveal({ id, sample }) {
  const [prediction, meaning] = replay.classes[sample.prediction];
  const [truth] = replay.classes[sample.truth];
  const matches = sample.prediction === sample.truth;
  elements.prediction.textContent = prediction;
  elements.prediction.className = prediction.length > 5 ? "prediction long" : "prediction";
  elements.meaning.textContent = meaning;
  elements.truth.textContent = truth;
  elements.verdict.textContent = matches ? "标签一致" : "标签不一致";
  elements.verdict.classList.toggle("mismatch", !matches);
  elements.verdict.hidden = false;
  showStatus("回放完成");
  replay.renderWave(elements.waveform, sample.peaks, 1);
  addRecord(id, prediction, truth, matches, "离线");
}

function clearBoardMetrics() {
  for (const key of ["board-cycles", "board-time", "board-check"]) elements[key].textContent = "—";
  if (boardSession?.mode === "keyword") elements["board-cases"].textContent = "等待板端识别";
}

function showBoardResult(current, result) {
  if (result.sample_id !== Number(current.id)) throw new Error("回传的编号与下发不符");
  if (boardSession.mode === "keyword") {
    if (result.mode !== "keyword" || result.layers !== 12 || !Object.hasOwn(replay.classes, result.prediction)) {
      throw new Error("完整识别回执异常，请重新连接 J8");
    }
    const [prediction, meaning] = replay.classes[result.prediction];
    const [truth] = replay.classes[current.sample.truth];
    const matches = result.prediction === current.sample.truth;
    elements.prediction.textContent = prediction;
    elements.prediction.className = prediction.length > 5 ? "prediction long" : "prediction";
    elements.meaning.textContent = `${meaning} · 板端识别`;
    elements.truth.textContent = truth;
    elements.verdict.textContent = matches ? "标签一致" : "标签不一致";
    elements.verdict.classList.toggle("mismatch", !matches);
    elements.verdict.hidden = false;
    elements["board-cycles"].textContent = result.active_cycles;
    const coreMs = (result.active_cycles * 1000 / boardSession.clock_hz).toFixed(2);
    elements["board-time"].textContent = `${coreMs} ms`;
    elements["board-check"].textContent = `${result.layers}/12`;
    elements["board-cases"].textContent = `含串口传输 ${result.elapsed_seconds.toFixed(2)} s`;
    showStatus(`#${current.id} 已回传`);
    addRecord(current.id, prediction, truth, matches, "FPGA");
    return;
  }
  if (result.mode === "keyword") throw new Error("板端位流已切换，请重新连接 J8");
  elements.truth.textContent = `#${current.id}`;
  if (result.status === 2) {
    elements.prediction.textContent = "已回传";
    elements.prediction.className = "prediction long";
    elements.meaning.textContent = "此编号未装载板端点积向量";
    elements["board-check"].textContent = "无向量";
  } else {
    elements.prediction.textContent = `${result.matches}/2`;
    elements.prediction.className = "prediction";
    elements.meaning.classList.add("board-output");
    elements.meaning.textContent = `点积 0  ${result.dot0}\n点积 1  ${result.dot1}`;
    elements.verdict.textContent = result.status === 0 ? "点积一致" : "点积不一致";
    elements.verdict.classList.toggle("mismatch", result.status !== 0);
    elements.verdict.hidden = false;
    elements["board-cycles"].textContent = result.cycles;
    elements["board-time"].textContent = `${(result.cycles * 1e6 / boardSession.clock_hz).toFixed(2)} μs`;
    elements["board-check"].textContent = `${result.matches}/2`;
  }
  showStatus(`#${current.id} 已回传`);
}

function refreshBoardMode() {
  const live = Boolean(boardSession);
  const full = boardSession?.mode === "keyword";
  elements["run-mode"].textContent = full ? "FPGA 实时识别" : live ? "J8 点积联调" : "离线评测回放";
  elements["sample-scope"].textContent = live && !full ? "4 条板载点积样本" : "600 条样本 · 12 类";
  elements["board-link"].textContent = live ? `${boardSession.port} · ${boardSession.baud}` : "FPGA 未接入";
  elements["board-link"].classList.toggle("connected", live);
  elements["board-switch"].textContent = live ? "切回离线" : "连接 J8";
  elements["result-title"].textContent = full ? "FPGA 识别结果" : live ? "板端点积结果" : "识别结果";
  elements["truth-label"].textContent = live && !full ? "板端回传编号" : "真实标签";
  elements["check-label"].textContent = full ? "编码层数" : live ? "点积校验" : "末层校验";
  elements.play.textContent = full ? "开始板端识别" : live ? "下发样本编号" : "播放并揭晓";
  elements.layers.hidden = live;
  elements["board-cases"].hidden = !live;
  elements["board-cases"].textContent = full ? "等待板端识别" : live ? `上板样本  ${boardSession.samples.join(" · ")}` : "";
  clearBoardMetrics();
  if (selection) selectSample(Number(selection.id));
  else clearResult(live ? "等待抽取上板样本" : "等待播放");
}

async function toggleBoardMode() {
  if (playing || switchingMode) return;
  switchingMode = true;
  refreshControls();
  try {
    if (boardSession) boardSession = null;
    else {
      elements["board-link"].textContent = "连接中";
      boardSession = await board.connect();
    }
    refreshBoardMode();
  } catch (error) {
    refreshBoardMode();
    showStatus(error.message, true);
  } finally {
    switchingMode = false;
    refreshControls();
  }
}

async function runSelection() {
  if (!selection || playing || switchingMode) return;
  const current = selection;
  playing = true;
  refreshControls();
  clearResult(boardSession ? "等待板端回传" : "正在播放样本");
  showStatus(boardSession ? "下发中" : "播放中");
  clearBoardMetrics();

  try {
    if (boardSession?.mode === "keyword") {
      const audio = playSelection(current).then(() => true, () => false);
      try {
        showBoardResult(current, await board.run(Number(current.id)));
        if (!(await audio)) showStatus(`#${current.id} 已回传 · 音频未播放`);
      } finally {
        await audio;
      }
    } else if (boardSession) {
      showBoardResult(current, await board.run(Number(current.id)));
    } else {
      await playSelection(current);
      reveal(current);
    }
  } catch (error) {
    clearResult("等待重试");
    showStatus(boardSession ? error.message : "音频无法播放", true);
  } finally {
    playing = false;
    refreshControls();
  }
}

function playSelection({ sample }) {
  return replay.playSample(elements.audio, sample, audioRoot, progress => {
    replay.renderWave(elements.waveform, sample.peaks, progress);
  });
}

function setProjection(active) {
  document.body.classList.toggle("presenting", active);
  elements.projection.setAttribute("aria-pressed", String(active));
  elements.projection.textContent = active ? "退出投屏" : "进入投屏";
}

async function toggleProjection() {
  const active = !document.body.classList.contains("presenting");
  setProjection(active);
  if (!active && document.fullscreenElement) {
    await document.exitFullscreen();
  } else if (active && document.documentElement.requestFullscreen) {
    try {
      await document.documentElement.requestFullscreen();
    } catch {
      // 嵌入式浏览器禁用全屏时仍可使用放大的投屏布局。
    }
  }
}

elements.draw.addEventListener("click", () => {
  const candidates = boardSession?.samples;
  const index = Math.floor(Math.random() * (candidates?.length ?? samples.length));
  selectSample(candidates ? candidates[index] : index);
});
elements["sample-form"].addEventListener("submit", event => {
  event.preventDefault();
  selectSample(Number(elements["sample-number"].value));
});
elements.play.addEventListener("click", runSelection);
elements["board-switch"].hidden = !board.enabled;
elements["board-switch"].addEventListener("click", toggleBoardMode);
elements.projection.addEventListener("click", toggleProjection);
document.addEventListener("fullscreenchange", () => {
  if (!document.fullscreenElement) setProjection(false);
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && !document.fullscreenElement) setProjection(false);
});

for (let layer = 0; layer < 12; layer += 1) {
  const cell = document.createElement("li");
  cell.textContent = `L${layer}`;
  cell.setAttribute("aria-label", `L${layer} 层暂无板载状态`);
  elements.layers.append(cell);
}
replay.renderWave(elements.waveform);
