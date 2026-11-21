"use strict";

const replayClasses = {
  _silence_: ["SILENCE", "静音"],
  _unknown_: ["UNKNOWN", "范围外语音"],
  yes: ["YES", "确认"],
  no: ["NO", "拒绝"],
  up: ["UP", "向上"],
  down: ["DOWN", "向下"],
  left: ["LEFT", "向左"],
  right: ["RIGHT", "向右"],
  on: ["ON", "开启"],
  off: ["OFF", "关闭"],
  stop: ["STOP", "停止"],
  go: ["GO", "前进"],
};

function renderWave(canvas, peaks = [], progress = 0) {
  const context = canvas.getContext("2d");
  const { width, height } = canvas;
  const middle = height / 2;
  context.clearRect(0, 0, width, height);

  context.strokeStyle = "#c9dfec";
  context.beginPath();
  for (let column = 0; column <= 8; column += 1) {
    const x = Math.round(column * width / 8) + .5;
    context.moveTo(x, 12);
    context.lineTo(x, height - 12);
  }
  context.moveTo(0, middle + .5);
  context.lineTo(width, middle + .5);
  context.stroke();
  if (peaks.length === 0) return;

  const step = width / peaks.length;
  peaks.forEach((peak, index) => {
    const extent = Math.max(1.5, peak * (height - 16) / 100);
    context.fillStyle = (index + 1) / peaks.length <= progress ? "#008775" : "#237bb6";
    context.fillRect(index * step + 2, middle - extent / 2, Math.max(1, step - 4), extent);
  });
}

function waitForSilence(duration, onProgress) {
  return new Promise(resolve => {
    const started = performance.now();
    let frame;
    function tick(now) {
      onProgress(Math.min(1, (now - started) / (duration * 1000)));
      frame = requestAnimationFrame(tick);
    }
    frame = requestAnimationFrame(tick);
    // 在后台标签页中也按时结束静音回放。
    setTimeout(() => {
      cancelAnimationFrame(frame);
      resolve();
    }, duration * 1000);
  });
}

function playSample(audio, sample, audioRoot, onProgress) {
  if (!sample.audio) return waitForSilence(sample.duration, onProgress);

  return new Promise((resolve, reject) => {
    const events = new AbortController();
    const options = { signal: events.signal };
    audio.addEventListener("timeupdate", () => onProgress(Math.min(1, audio.currentTime / sample.duration)), options);
    audio.addEventListener("ended", () => {
      events.abort();
      resolve();
    }, options);
    const fail = () => {
      events.abort();
      reject(new Error("无法播放音频"));
    };
    audio.addEventListener("error", fail, options);
    audio.src = new URL(sample.audio, new URL(audioRoot, document.baseURI));
    audio.play().catch(fail);
  });
}

window.kwtReplay = { classes: replayClasses, renderWave, playSample };
