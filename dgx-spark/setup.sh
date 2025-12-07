#!/bin/bash
# DGX Spark Embedding Server Setup Script
# Run this INSIDE the NGC PyTorch container
#
# IMPORTANT: This was painful to figure out. Don't deviate from these steps.

set -e

echo "=== DGX Spark NV-Embed-v2 Server Setup ==="
echo ""

# Check if we're in a container
if [ ! -f /.dockerenv ]; then
    echo "ERROR: This script should be run inside the NGC PyTorch container."
    echo ""
    echo "First, run:"
    echo "  docker run -it --runtime=nvidia --gpus=all -p 8080:8080 \\"
    echo "    -v \$HOME/.cache/huggingface:/root/.cache/huggingface \\"
    echo "    nvcr.io/nvidia/pytorch:25.10-py3"
    echo ""
    exit 1
fi

# Check GPU
echo "Checking GPU..."
python -c "import torch; print(f'CUDA: {torch.cuda.is_available()}, GPU: {torch.cuda.get_device_name(0)}')"
echo ""

# Create and activate venv (REQUIRED to avoid NVIDIA package conflicts)
echo "Creating virtual environment..."
python -m venv /workspace/venv
source /workspace/venv/bin/activate
echo "Virtual environment activated."
echo ""

# Install CUDA-enabled PyTorch (venv defaults to CPU-only!)
echo "Installing CUDA-enabled PyTorch (cu130 for GB10)..."
pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu130
echo ""

# Verify CUDA
echo "Verifying CUDA..."
python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available!'; print('CUDA: OK')"
echo ""

# Install dependencies with PINNED transformers version
echo "Installing dependencies (transformers pinned to 4.44.0 for NV-Embed-v2 compatibility)..."
pip install transformers==4.44.0
pip install fastapi uvicorn datasets einops
echo ""

# Install hf-transfer for faster model downloads
echo "Installing hf-transfer for faster downloads..."
pip install hf-transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
echo ""

# Create the embedding server (uses AutoModel, NOT SentenceTransformer)
echo "Creating embedding_server.py..."
cat > /workspace/embedding_server.py << 'INNEREOF'
from fastapi import FastAPI
from pydantic import BaseModel
import torch
from transformers import AutoModel

app = FastAPI()
print("Loading NV-Embed-v2...")
model = AutoModel.from_pretrained('nvidia/NV-Embed-v2', trust_remote_code=True)
model = model.to('cuda')
model.eval()
print("Model loaded on cuda")

class EmbedRequest(BaseModel):
    inputs: list[str]

@app.post("/embed")
def embed(request: EmbedRequest):
    max_length = 32768
    with torch.no_grad():
        embeddings = model.encode(request.inputs, max_length=max_length)
        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
    return embeddings.cpu().tolist()

@app.get("/health")
def health():
    return {"status": "ok", "model": "NV-Embed-v2", "dimensions": 4096}
INNEREOF
echo ""

echo "=== Setup Complete ==="
echo ""
echo "To start the server, run:"
echo "  source /workspace/venv/bin/activate"
echo "  python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080"
echo ""
echo "The first run will download NV-Embed-v2 (~15GB)."
echo ""
echo "Test with:"
echo "  curl http://<spark-ip>:8080/health"
echo "  curl -X POST http://<spark-ip>:8080/embed -H 'Content-Type: application/json' -d '{\"inputs\": [\"test\"]}'"
