import argparse
import json
from pathlib import Path
from queue import Empty, SimpleQueue
from threading import Thread
import tkinter as tk
import winsound

from demo_protocol import (BAUD, BLOCK_BYTES, PROJECT, encoder_payload, get_samples,
                           prepare_predictor, run_encoder, run_mac, serial_module)


def log_result(result):
    directory = PROJECT / "build"
    directory.mkdir(exist_ok=True)
    with (directory / "live_runs.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps(result, ensure_ascii=False) + "\n")


def run_gui(args, samples, predictor, serial):
    window = tk.Tk()
    window.geometry("880x510")
    window.title("KWT-STAR · FPGA 语音小车")
    window.configure(bg="#0a161e")
    title = "12 层编码 · " + ("实时分类头" if predictor else "已知样本校验") if args.mode == "full" else "W4 双项点积 · FPGA 算子演示"
    message = tk.StringVar(value="选择一条录音")
    command = tk.StringVar(value="READY")
    tk.Label(window, text=title, font=("Microsoft YaHei UI", 20), bg="#0a161e", fg="#e8f5f1").pack(pady=25)
    tk.Label(window, textvariable=command, font=("Segoe UI", 65, "bold"), bg="#0a161e", fg="#75f0c9").pack(pady=12)
    tk.Label(window, textvariable=message, font=("Microsoft YaHei UI", 15), bg="#0a161e", fg="#e8f5f1").pack(pady=15)
    controls = tk.Frame(window, bg="#0a161e")
    controls.pack(pady=20)
    buttons = []
    mailbox = SimpleQueue()

    def finish():
        try:
            result = mailbox.get_nowait()
        except Empty:
            window.after(50, finish)
            return
        for button in buttons:
            button.configure(state=tk.NORMAL)
        if isinstance(result, Exception):
            command.set("ERROR")
            message.set(str(result))
        else:
            command.set(result["display"] or "CHECK")
            if result["mode"] == "full":
                message.set(f"{result['layers']}/12 层   {result['matched_words']:,}/6,336 字   "
                            f"{result['active_cycles']:,} 拍（扣除等参）   串口流程 {result['elapsed_seconds']:.1f}s")
            else:
                message.set("两个原始点积均与参考一致" if result["ok"] else "板上点积校验失败")

    def launch(sample):
        for button in buttons:
            button.configure(state=tk.DISABLED)
        command.set("RUNNING")
        message.set(f"{sample.name} · {args.port}")
        winsound.PlaySound(str(sample.audio), winsound.SND_FILENAME | winsound.SND_ASYNC)

        def work():
            try:
                with serial.Serial(args.port, BAUD, timeout=6, write_timeout=6) as port:
                    result = run_mac(port, sample) if args.mode == "mac" else run_encoder(port, sample, samples, predictor)
                log_result(result)
                mailbox.put(result)
            except (OSError, ValueError, RuntimeError) as exc:
                mailbox.put(exc)

        Thread(target=work, daemon=True).start()
        window.after(50, finish)

    for sample in samples.values():
        button = tk.Button(controls, text=sample.label, width=7, padx=8, pady=10,
                           font=("Segoe UI", 16, "bold"), command=lambda selected=sample: launch(selected))
        button.pack(side=tk.LEFT, padx=10)
        buttons.append(button)
    window.mainloop()


def main():
    parser = argparse.ArgumentParser(description="KWT-STAR FPGA 语音小车演示")
    parser.add_argument("--port", help="J8 板载 PL 串口，例如 COM7")
    parser.add_argument("--mode", choices=("mac", "full"), default="mac")
    verify = parser.add_mutually_exclusive_group()
    verify.add_argument("--sample", choices=("RIGHT", "UP", "LEFT", "STOP"), help="命令行运行单样本")
    verify.add_argument("--verify-all", action="store_true", help="一次验收四条指令并记录结果")
    parser.add_argument("--head-dir", type=Path, help="原提交包的 numeric_model 路径")
    parser.add_argument("--check-assets", action="store_true")
    args = parser.parse_args()
    samples = get_samples()
    if args.check_assets:
        for sample in samples.values():
            payload = encoder_payload(sample)
            print(f"{sample.name} {sample.label} {len(payload)} 字节 {len(payload)//BLOCK_BYTES + 1} 块")
        return
    if not args.port:
        parser.error("请指定 J8 对应的 --port")
    predictor = prepare_predictor(args.head_dir)
    serial = serial_module()
    if args.sample or args.verify_all:
        selected = samples.values() if args.verify_all else (samples[args.sample],)
        passed = True
        with serial.Serial(args.port, BAUD, timeout=6, write_timeout=6) as port:
            for sample in selected:
                if args.mode == "mac":
                    result = run_mac(port, sample)
                else:
                    artifact = PROJECT / "build" / "board_readback" / f"{sample.name}_layer_11.bin"
                    result = run_encoder(port, sample, samples, predictor, readback_path=artifact)
                log_result(result)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                passed &= result["ok"] and result["display"] == sample.label
        if not passed:
            raise SystemExit(1)
    else:
        run_gui(args, samples, predictor, serial)


if __name__ == "__main__":
    main()
