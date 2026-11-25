# dsv4-flash：兩台 DGX Spark 跑 DeepSeek V4 Flash（vLLM TP=2）

這個 repo 把兩台 NVIDIA DGX Spark（GB10，各 128 GB unified memory）用 ConnectX-7 直連起來，以 **vLLM tensor parallel 2** 跑官方的 [`deepseek-ai/DeepSeek-V4-Flash-0731`](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)，提供 OpenAI 相容 API。

| 項目 | 內容 |
|---|---|
| 模型 | DeepSeek V4 Flash 0731，284B MoE / 約 13B active，FP8 權重 + FP4 MoE，約 167 GB |
| 推論引擎 | **vLLM** 0.25（`0.25.2.dev0+g752a3a504`），使用 [anemll/dspark-vllm-gx10](https://github.com/anemll/dspark-vllm-gx10) 的 GB10 移植版 image |
| 平行方式 | Tensor parallel 2，vLLM 內建多機模式（`--nnodes 2`、`mp` backend，不用 Ray） |
| 網路 | ConnectX-7 點對點直連，RoCE v2，MTU 9000 |
| KV cache | `nvfp4_ds_mla`，可放 797,000 tokens |
| Speculative decoding | DSpark MTP-5 |
| Context | 350,000 tokens，最多 12 個並行請求 |
| 實測速度 | 單一請求約 **39 tok/s**（從另一台電腦計時，含 prefill 與網路） |

---

## 快速開始

前提：兩台 Spark 已用 QSFP 線直連、設好 fabric IP 與 MTU 9000，head 可以免密碼 SSH 到 worker，兩台都裝好 Docker 與 NVIDIA Container Toolkit（DGX OS 預設已有）。

```bash
# 1. 在你自己的電腦上：把這個資料夾推到 head（或直接在 head 上 git clone）
./deploy.sh

# 2. 以下都在 head 上執行
cd ~/dsv4-flash
scripts/check-fabric.sh      # 檢查 MTU 9000、RoCE v2 GID、RDMA 頻寬
scripts/download-model.sh    # 下載 167 GB 到 head，再經 CX7 rsync 到 worker 並比對
scripts/start.sh             # 先啟動 worker 再啟動 head，等 /health 回 200
scripts/smoke.sh             # 打一個測試請求並顯示 tok/s
```

API：`http://<head 的 LAN IP>:8888/v1`，模型名稱 `deepseek-v4-flash`。

```bash
curl http://192.168.1.112:8888/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "deepseek-v4-flash",
  "messages": [{"role": "user", "content": "你好"}],
  "chat_template_kwargs": {"thinking": true}
}'
```

其他指令：`scripts/stop.sh`（停止兩台）、`scripts/logs.sh [worker]`（追 log）。

---

## 套用到你自己的機器

所有跟機器有關的值都集中在 `config/`。我的環境如下，換成你的就能用：

| 角色 | 主機 | LAN | CX7 fabric IP | 網卡 / RDMA 裝置 |
|---|---|---|---|---|
| head（rank 0，提供 API） | JoshDGX | 192.168.1.112 | 10.20.0.11 | `enp1s0f0np0` / `rocep1s0f0` |
| worker（rank 1，headless） | JoshDGX2 | 192.168.1.93 | 10.20.0.12 | `enp1s0f0np0` / `rocep1s0f0` |

要改的地方：

- `config/common.env`：`MODEL_DIR`、`HF_CACHE`、`MASTER_ADDR`（head 的 fabric IP）、`NCCL_IB_HCA`、`FABRIC_IF`
- `config/head.env` / `config/worker.env`：各自的 `VLLM_HOST_IP`（fabric IP）
- `scripts/common.sh`：`WORKER`（worker 的 fabric IP）
- `deploy.sh`：head 的 SSH 名稱

查自己的網卡和 RDMA 裝置對應：

```bash
ibdev2netdev          # 例如 rocep1s0f0 port 1 ==> enp1s0f0np0 (Up)
ip -br addr
```

---

## 怎麼做起來的

以下是實際的建置過程，包含做選擇的理由和踩到的坑。

### 1. 先算記憶體：為什麼選 DeepSeek V4 Flash

兩台合計 256 GB，但每台扣掉 OS 後 GPU 大約只能用 121 GiB，合計約 240 GB，還要留空間給 KV cache。所以權重要控制在 200 GB 以內才有餘裕。

- DeepSeek V3/R1（671B）、Kimi、Qwen3.8 這類 Q4 都要 380 GB 以上，放不下。
- DeepSeek V4 Flash 是 284B MoE，每個 token 只動用約 13B 參數，官方 checkpoint 約 167 GB，兩台各載一半後還剩約 10 GiB 給 KV cache。
- Spark 的記憶體頻寬只有 273 GB/s，active 參數越少就越快。13B active 加上 speculative decoding，是兩台 Spark 上速度和能力最平衡的選擇。
- 單台放不下：權重本身 155 GiB 就超過一台的 121 GiB，所以一定要兩台 TP=2。

### 2. 選推論引擎：為什麼是 vLLM，不是 SGLang 或 llama.cpp

- **llama.cpp RPC**：架設最簡單，但它只是把記憶體疊起來，不會讓速度變快，prefill 也慢。
- **SGLang**：社群在 Spark 上主要拿來跑 Qwen3.5-397B 這類 NVFP4 模型。我找到的 DeepSeek V4 Flash 雙 Spark 驗證 recipe（含 DSpark speculative decoding 與 `nvfp4_ds_mla` KV cache）都是 vLLM。
- **主線 vLLM**：GB10 是 SM121 架構，社群 recipe 跑 DeepSeek V4 時都是用加了 SM121 patch 的移植版，而不是直接用主線 image。
- **anemll/dspark-vllm-gx10**：基於 vLLM 0.25.1，補上 SM121 的 FlashInfer sparse-MLA、b12x MXFP4 MoE backend 和 `nvfp4_ds_mla`，已在兩台 GB10 上驗證過，而且有預先建好的 ARM64 image。最後選這個。

Image 用 digest 鎖定（`sha256:a839…c9d8`），確保兩台跑的程式完全相同。

### 3. 確認網路：RoCE 才有意義

TP=2 每一層都要做 all-reduce，如果 NCCL 退回一般 TCP socket，速度會大幅下降。實際檢查了：

```bash
ibdev2netdev                                   # 確認 rocep1s0f0 <-> enp1s0f0np0 是 Up
cat /sys/class/infiniband/rocep1s0f0/ports/1/rate             # 200 Gb/sec (2X NDR)
cat /sys/class/infiniband/rocep1s0f0/ports/1/gid_attrs/types/3  # RoCE v2
ping -M do -s 8972 10.20.0.12                  # 確認 MTU 9000 不分片
ib_write_bw -d rocep1s0f0 -x 3 -F --report_gbits 10.20.0.12
```

`ib_write_bw` 實測 **109 Gb/s**。GB10 的 CX7 一個 QSFP port 在系統裡會分成兩個 PCIe half（`rocep1s0f0` 和 `roceP2p1s0f0`），單一 half 大約就是這個數字。這些檢查都寫進了 `scripts/check-fabric.sh`。

容器設定的重點是 `network_mode: host`、`ipc: host`、`--device /dev/infiniband`、`memlock: -1`，NCCL 環境變數設 `NCCL_NET=IB`、`NCCL_IB_HCA==rocep1s0f0`、`NCCL_IB_ROCE_VERSION_NUM=2`、`NCCL_IB_ADDR_FAMILY=AF_INET`。GID index 不寫死，讓 NCCL 自己挑 RoCE v2 的 IPv4 GID。

### 4. 下載與複製模型

`download-model.sh` 直接用 vLLM image 裡的 `huggingface_hub` 下載，不用在主機上另外裝 Python 套件。我這邊家用網路約 520 Mbps，167 GB 下載大約 45 分鐘。

下載完再用 rsync 經 CX7 複製到 worker，**6 分 21 秒，約 417 MB/s**，比兩台各自從網路下載快很多。腳本最後會比對兩邊的檔案清單和大小。

### 5. Compose 設定

`docker-compose.yml` 以 anemll 的設定為基礎精簡而來，兩台用同一個檔案，用 `config/common.env` 加上 `head.env` 或 `worker.env` 區分角色。主要參數：

```
vllm serve /models/dsv4 \
  --tensor-parallel-size 2 --nnodes 2 --node-rank {0|1} --master-addr 10.20.0.11 \
  --distributed-executor-backend mp \
  --kv-cache-dtype nvfp4_ds_mla --block-size 256 \
  --max-model-len 350000 --max-num-seqs 12 --gpu-memory-utilization 0.78 \
  --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic"}' \
  --moe-backend flashinfer_b12x --tokenizer-mode deepseek_v4 \
  --tool-call-parser deepseek_v4 --enable-auto-tool-choice --reasoning-parser deepseek_v4 \
  --enable-prefix-caching --enable-chunked-prefill --async-scheduling
  # worker 另外加 --headless
```

另外做了一件 anemll 原本沒做的事：anemll 的 image 是 0731 版發布前建的，所以容器啟動時會把 checkpoint 裡的 `encoding/encoding_dsv4.py` 複製進 vLLM，讓 chat 格式對齊 0731 版。

### 6. 啟動

`start.sh` 會先檢查兩台的 GPU 是否空著，再同步設定到 worker、確認 image 存在，然後**先啟動 worker，15 秒後才啟動 head**。兩邊同時起來可能會卡在 TCPStore/NCCL 的 rendezvous。

第一次啟動實際花了約 8 分鐘：

| 階段 | 時間 |
|---|---|
| 載入權重 | worker 74 秒，head 約 2.5 分鐘 |
| TileLang JIT 編譯 + FlashInfer autotune | 數分鐘 |
| CUDA graph capture | 44 秒 |
| KV cache | 每台 10 GiB，合計 797,000 tokens，350K 的請求可同時放 2.28 個 |

JIT 編譯結果存在 `~/.cache/huggingface`，之後重啟會快很多。

### 7. 踩到的坑

- **遠端登入 shell 是 zsh**：用 SSH 叫 worker 執行 `source common.sh` 時，zsh 不認得 `BASH_SOURCE`。後來改成遠端一律用 `bash scripts/compose.sh ...` 執行。
- **env 檔會吃掉引號**：原本把 `{"thinking":false}` 整串放在 env 檔，Compose 解析後變成 `{thinking:false}`，不是合法 JSON。後來改成只放 `DEFAULT_THINKING=false`，JSON 寫在 compose 檔裡。
- **macOS 內建 bash 3.2**：在 `set -u` 下展開空陣列會直接報錯，`smoke.sh` 改用 `${AUTH[@]+"${AUTH[@]}"}`。
- **下載期間區網 SSH 斷過一次**：下載本身跑在 head 上的 `nohup`，不受影響，但監看程式要能容忍 SSH 暫時連不上。
- **GPU 要空出來**：每台約占 108 GB，head 上原本跑的另一個 vLLM 容器要先停掉，`start.sh` 會檢查。
- **兩台 driver 版本不同**（595.99 和 580.178）：這次沒有出問題，但如果 NCCL 初始化卡住，先把版本調成一致。

### 8. 驗證

```bash
$ HOST=192.168.1.112 scripts/smoke.sh
...
--- 233 tokens in 5.9s  ≈ 39.2 tok/s (includes prefill)
```

第一次請求約 26 tok/s（還在暖機），之後穩定在約 39 tok/s。這個數字是從另一台電腦計時，包含 prefill 和網路來回，純 decode 會再高一些。anemll 在同一個 image 上量到的單一請求約 48 tok/s，量法不完全相同。

---

## 調整

都在 `config/common.env`，改完跑 `scripts/start.sh` 重啟：

| 設定 | 說明 |
|---|---|
| `MAX_MODEL_LEN` / `MAX_NUM_SEQS` | context 長度與並行請求數 |
| `GPU_MEMORY_UTILIZATION` | 預設 0.78；調高可以多一點 KV cache，但要留空間給系統 |
| `MTP_NUM_TOKENS` | speculative token 數，預設 5；技術類輸出接受率偏低時可以試 3 |
| `DEFAULT_THINKING` | 預設是否開推理；單次請求可用 `chat_template_kwargs` 覆寫 |
| `NCCL_IB_HCA==rocep1s0f0,roceP2p1s0f0` | 同時使用 CX7 的兩個 PCIe half（實驗性，未驗證） |
| `NCCL_DEBUG=INFO` | 在 log 裡確認是 `NET/IB`（RoCE）而不是 `NET/Socket` |

API key：建立 `config/secret.env`，內容寫 `VLLM_API_KEY=...`（已列入 `.gitignore`）。

## 已知限制

- 只把 0731 的 chat encoder 裝進 image。如果大量使用 tool calling 或 reasoning effort（low/high/max），可以參考 [MiaAI-Lab 的 recipe](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark) 裡額外的 hotfix。
- API 預設綁在 `0.0.0.0` 且沒有驗證，只適合可信任的區網。

## 檔案結構

```
docker-compose.yml        兩台共用的 vLLM 服務定義
config/common.env         共用設定（image、模型路徑、NCCL、serving 參數）
config/head.env           rank 0
config/worker.env         rank 1（headless）
scripts/check-fabric.sh   網路檢查
scripts/download-model.sh 下載並複製模型
scripts/start.sh          worker 先、head 後啟動，等待 /health
scripts/stop.sh / logs.sh / smoke.sh / compose.sh
deploy.sh                 從自己的電腦推到 head
```

## 致謝與授權

- [anemll/dspark-vllm-gx10](https://github.com/anemll/dspark-vllm-gx10)：vLLM GB10 移植 image 與 compose 設定的基礎（MIT，授權全文見 `third_party/`）
- [MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)：0731 encoder 處理方式與雙機經驗
- 模型權重由 DeepSeek 以 MIT 授權發布，不包含在本 repo

本 repo 以 MIT 授權釋出。
