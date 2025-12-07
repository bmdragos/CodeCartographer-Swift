"""
NV-Embed-v2 Embedding Server for DGX Spark

FastAPI server that provides embeddings using NVIDIA's NV-Embed-v2 model.
Designed to run on DGX Spark's GB10 GPU.

IMPORTANT: This uses AutoModel directly, NOT the SentenceTransformer wrapper,
because the wrapper has compatibility issues with NV-Embed-v2's custom code.

Requirements:
    - transformers==4.44.0 (pinned for compatibility)
    - torch with cu130 (for GB10 sm_121 support)
    
Usage:
    python -m uvicorn embedding_server:app --host 0.0.0.0 --port 8080

Endpoints:
    POST /embed - Generate embeddings for a list of texts
    GET /health - Health check
"""

from fastapi import FastAPI
from pydantic import BaseModel
import torch
from transformers import AutoModel

app = FastAPI(
    title="NV-Embed-v2 Server",
    description="Embedding server for CodeCartographer semantic search",
    version="1.0.0"
)

print("Loading NV-Embed-v2 (7B model, may take a minute)...")
model = AutoModel.from_pretrained('nvidia/NV-Embed-v2', trust_remote_code=True)
model = model.to('cuda')
model.eval()
print(f"Model loaded on cuda")


class EmbedRequest(BaseModel):
    inputs: list[str]


@app.post("/embed")
def embed(request: EmbedRequest) -> list[list[float]]:
    """Generate embeddings for a list of texts."""
    max_length = 32768
    with torch.no_grad():
        embeddings = model.encode(request.inputs, max_length=max_length)
        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
    return embeddings.cpu().tolist()


@app.get("/health")
def health() -> dict:
    """Health check endpoint."""
    return {
        "status": "ok", 
        "model": "NV-Embed-v2", 
        "dimensions": 4096,
        "device": "cuda"
    }
