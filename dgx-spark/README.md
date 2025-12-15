# DGX Spark Embedding Server

FastAPI server running NV-Embed-v2 on DGX Spark for CodeCartographer semantic search.

**Version:** 2.0.7

> **Setup is finicky.** The GB10 GPU (Blackwell sm_121) is new hardware with limited PyTorch support. Follow this guide exactly.

## Quick Start

```bash
# 1. SSH into DGX Spark
ssh spark-dcf7.local

# 2. Login to NGC (get API key from ngc.nvidia.com)
docker login nvcr.io
# Username: $oauthtoken
# Password: <your-api-key>

# 3. Run NGC container with cache mount
docker run -it --runtime=nvidia --gpus=all -p 8080:8080 \
  -v $HOME/.cache/huggingface:/root/.cache/huggingface \
  nvcr.io/nvidia/pytorch:25.10-py3

# 4. Inside container: create venv (required!)
python -m venv /workspace/venv
source /workspace/venv/bin/activate

# 5. Install CUDA-enabled PyTorch
pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu130

# 6. Verify CUDA works
python -c "import torch; print(torch.cuda.is_available())"  # Must be True

# 7. Install dependencies (pinned versions matter!)
pip install transformers==4.44.0 fastapi uvicorn datasets einops

# 8. Copy embedding_server.py to container and run
python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080
```

## Restart Server (Container Already Exists)

```bash
# SSH into DGX
ssh spark-dcf7.local

# Find container
docker ps -a | grep pytorch

# Start and enter
docker start <container_id>
docker exec -it <container_id> bash

# Inside container:
source /workspace/venv/bin/activate
python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080
```

## Update Server Code

```bash
# From your Mac - copy updated file to DGX and into container
scp dgx-spark/embedding_server.py spark-dcf7.local:/tmp/
ssh spark-dcf7.local "docker cp /tmp/embedding_server.py <container_id>:/workspace/"

# Restart server (kill existing, start new)
ssh spark-dcf7.local "docker exec <container_id> pkill -f uvicorn"
ssh spark-dcf7.local "docker exec -d <container_id> bash -c 'source /workspace/venv/bin/activate && cd /workspace && python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080'"

# Verify (wait ~60s for model load)
curl http://192.168.1.159:8080/health
```

## Use with CodeCartographer

```swift
set_project(
  path: "/path/to/project",
  provider: "dgx",
  dgx_endpoint: "http://192.168.1.159:8080/embed"
  // batch_size is now auto-configured from server capabilities
)
```

CodeCartographer automatically queries `/capabilities` to get the recommended batch size based on available GPU memory.

## Job Queue System (v2.0)

The server supports multi-instance coordination via a job queue:

1. **Register job** - Client registers total chunks, gets job ID and recommended batch size
2. **Process batches** - Client sends batches, server tracks progress
3. **Monitor progress** - Web dashboard shows real-time progress for all jobs
4. **Queue management** - Multiple projects queue automatically, processed FIFO

### Multi-Instance Support

Multiple CodeCartographer instances (e.g., Claude Code + Windsurf) can index different projects simultaneously:
- Jobs queue automatically when GPU is busy
- Each instance tracks its own job via job ID
- Progress visible in shared web dashboard

### Job Resume

If a client disconnects mid-job:
- Job ID is saved to embedding cache
- On reconnect, client checks if job is still valid
- If valid, resumes from current progress
- If invalid (server restarted), starts new job

**Future improvements:**
- Client-side skip - filter out already-embedded chunks before sending to server, so cached embeddings aren't re-computed after server restart
- Queue timeout handling - increase client timeout or add retry logic for jobs waiting behind long-running jobs

## Batch Size

Batch size is now **dynamically calculated** based on GPU memory:

| GPU Available | Recommended Batch |
|---------------|-------------------|
| > 80 GB | 64 |
| > 60 GB | 48 |
| > 40 GB | 32 |
| < 40 GB | 8 |

The `/capabilities` endpoint returns the current recommendation. CodeCartographer uses this automatically.

Manual override still available via `batch_size` parameter if needed.

## Performance (v2.0.4)

Inference optimizations provide ~60% throughput improvement:
- `torch.compile(mode="reduce-overhead")` - JIT compilation
- `torch.inference_mode()` - Faster than no_grad
- cuDNN benchmark mode - Auto-tuned kernels
- TF32 precision - Faster matmul on Ampere+

Typical throughput: **~50 embeddings/sec** at batch 48.

## Why This Exact Setup?

The GB10 requires `cu130` wheels which only exist for Python 3.12 on aarch64. Most paths fail:

| Attempt | Error |
|---------|-------|
| AI Workbench | Python 3.10, no cu130 wheels |
| Standard PyTorch (cu124/cu126) | `sm_121 is not compatible` |
| System Python in NGC | Package conflicts |
| venv without `--force-reinstall torch` | CPU-only torch |
| Latest transformers | `'DynamicCache' has no attribute 'get_usable_length'` |
| SentenceTransformer wrapper | `KeyError: 0` |
| flash_attention_2 | Not supported by NV-Embed-v2 |

**Working combo:** NGC `pytorch:25.10-py3` + venv + cu130 torch + `transformers==4.44.0` + `AutoModel` (not SentenceTransformer)

## Troubleshooting

**CUDA not available:** Reinstall torch with cu130 index URL.

**Out of memory:** Lower batch_size manually, or let server auto-adjust.

**Model download slow:** Use hardwired ethernet, enable `hf-transfer`:
```bash
pip install hf-transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
```

**Server crashed after restart:** Check logs for deprecated API warnings. PyTorch 2.9+ changed some TF32 APIs.

## Server Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /` | **Web dashboard** - auto-refreshing status with job progress |
| `POST /embed` | Generate embeddings. Body: `{"inputs": ["text1", "text2"]}` |
| `GET /health` | Health check with GPU memory stats |
| `GET /stats` | Runtime statistics (requests, latency, throughput) |
| `GET /capabilities` | GPU info and recommended batch size |
| `GET /jobs` | List active, queued, and recent jobs |
| `POST /jobs/register` | Register new indexing job |
| `POST /jobs/{job_id}/progress` | Update job progress |
| `POST /jobs/{job_id}/complete` | Mark job complete |
| `POST /jobs/{job_id}/fail` | Mark job failed |
| `DELETE /jobs/{job_id}` | Cancel job |

Open http://192.168.1.159:8080/ in a browser to see the dashboard.

## Model Info

- **Model:** nvidia/NV-Embed-v2 (7B params, Mistral-based)
- **Dimensions:** 4,096
- **Download:** ~15 GB
- **VRAM:** ~16 GB (fp16)
- **Requires:** `trust_remote_code=True`
