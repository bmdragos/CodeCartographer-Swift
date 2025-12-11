# DGX Spark Embedding Server

FastAPI server running NV-Embed-v2 on DGX Spark for CodeCartographer semantic search.

> ⚠️ **Setup is finicky.** The GB10 GPU (Blackwell sm_121) is new hardware with limited PyTorch support. Follow this guide exactly.

## Quick Start

```bash
# 1. SSH into DGX Spark
ssh user@192.168.1.159

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
ssh user@192.168.1.159

# Find container
docker ps -a | grep pytorch

# Start and enter
docker start <container_id>
docker exec -it <container_id> bash

# Inside container:
source /workspace/venv/bin/activate
python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080
```

## Use with CodeCartographer

```swift
set_project(
  path: "/path/to/project",
  provider: "dgx",
  dgx_endpoint: "http://192.168.1.159:8080/embed",
  batch_size: 48  // 8=safe, 32=fast, 48=optimal, 64=risky
)
```

## Batch Size Tuning

| Batch | Memory | Time (11K chunks) |
|-------|--------|-------------------|
| 8 | ~55 GB | ~12 min |
| 32 | ~74 GB | ~8 min |
| 48 | ~89 GB | ~6 min |
| 64 | ~117 GB | crashes |

Monitor memory via DGX Dashboard. Stay under 100 GB.

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

**Working combo:** NGC `pytorch:25.10-py3` + venv + cu130 torch + `transformers==4.44.0` + `AutoModel` (not SentenceTransformer)

## Troubleshooting

**CUDA not available:** Reinstall torch with cu130 index URL.

**Out of memory:** Lower batch_size.

**Model download slow:** Use hardwired ethernet, enable `hf-transfer`:
```bash
pip install hf-transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
```

## Model Info

- **Model:** nvidia/NV-Embed-v2 (7B params, Mistral-based)
- **Dimensions:** 4,096
- **Download:** ~15 GB
- **Requires:** `trust_remote_code=True`
