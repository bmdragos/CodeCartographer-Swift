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
    GET / - Web dashboard (auto-refreshing)
    POST /embed - Generate embeddings for a list of texts
    GET /health - Health check
    GET /stats - Server statistics
    GET /progress - Get indexing progress
    POST /progress - Update indexing progress (from CodeCartographer)
    DELETE /progress - Clear indexing progress
"""

import time
import asyncio
import logging
import uuid
from collections import deque
from dataclasses import dataclass, field
from typing import Optional
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel
import torch
from transformers import AutoModel

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
MAX_BATCH_SIZE = 64  # Prevent OOM on large requests
MAX_LENGTH = 32768   # NV-Embed-v2 max context

SERVER_VERSION = "2.0.4"

app = FastAPI(
    title="NV-Embed-v2 Server",
    description="Embedding server for CodeCartographer semantic search",
    version=SERVER_VERSION
)

# Gzip compression for responses (embeddings are ~16KB each, compresses well)
# minimum_size=1000 means only compress responses > 1KB
app.add_middleware(GZipMiddleware, minimum_size=1000)

# Statistics tracking
stats = {
    "requests": 0,
    "texts_embedded": 0,
    "total_time_ms": 0,
    "errors": 0,
    "started_at": time.time(),
    "queue_waits": 0,  # Times a request had to wait for GPU
    "queue_depth": 0   # Current number of requests waiting for GPU
}

# Job Queue Manager for multi-instance indexing
@dataclass
class IndexJob:
    id: str
    project: str
    total_chunks: int
    instance_id: str
    current: int = 0
    status: str = "queued"  # queued, active, completed, failed
    created_at: float = field(default_factory=time.time)
    started_at: Optional[float] = None
    completed_at: Optional[float] = None
    error: Optional[str] = None

    def to_dict(self) -> dict:
        result = {
            "id": self.id,
            "project": self.project,
            "total_chunks": self.total_chunks,
            "instance_id": self.instance_id,
            "current": self.current,
            "status": self.status,
            "created_at": self.created_at,
        }
        if self.started_at:
            result["started_at"] = self.started_at
            result["elapsed_seconds"] = round(time.time() - self.started_at, 1)
            if self.current > 0 and self.total_chunks > 0:
                rate = self.current / (time.time() - self.started_at)
                remaining = self.total_chunks - self.current
                result["eta_seconds"] = round(remaining / rate, 1) if rate > 0 else None
                result["chunks_per_second"] = round(rate, 1)
                result["percent"] = self.current * 100 // self.total_chunks
        if self.completed_at:
            result["completed_at"] = self.completed_at
            result["duration_seconds"] = round(self.completed_at - self.started_at, 1) if self.started_at else None
        if self.error:
            result["error"] = self.error
        return result


class JobQueue:
    """Manages indexing jobs across multiple CodeCartographer instances."""

    def __init__(self, max_workers: int = 1):
        self.max_workers = max_workers
        self.jobs: dict[str, IndexJob] = {}
        self.queue: deque[str] = deque()  # Job IDs waiting
        self.active: set[str] = set()  # Job IDs currently processing
        self.recent: list[IndexJob] = []  # Recently completed (keep last 10)
        self.lock = asyncio.Lock()
        # Track historical rate for ETA estimates
        self.total_chunks_processed = 0
        self.total_processing_time = 0.0

    async def register(self, project: str, total_chunks: int, instance_id: str) -> IndexJob:
        """Register a new indexing job. Returns job with position info."""
        async with self.lock:
            job_id = str(uuid.uuid4())[:8]
            job = IndexJob(
                id=job_id,
                project=project,
                total_chunks=total_chunks,
                instance_id=instance_id
            )
            self.jobs[job_id] = job
            self.queue.append(job_id)
            logger.info(f"Job registered: {job_id} ({project}, {total_chunks} chunks)")
            # Auto-activate if we have capacity
            await self._try_activate()
            return job

    async def _try_activate(self):
        """Activate queued jobs if we have worker capacity."""
        while len(self.active) < self.max_workers and self.queue:
            job_id = self.queue.popleft()
            job = self.jobs.get(job_id)
            if job and job.status == "queued":
                job.status = "active"
                job.started_at = time.time()
                self.active.add(job_id)
                logger.info(f"Job activated: {job_id} ({job.project})")

    async def update_progress(self, job_id: str, current: int) -> bool:
        """Update progress for a job. Returns False if job not found/active."""
        async with self.lock:
            job = self.jobs.get(job_id)
            if not job or job.status != "active":
                return False
            job.current = current
            return True

    async def complete(self, job_id: str) -> bool:
        """Mark job as completed."""
        async with self.lock:
            job = self.jobs.get(job_id)
            if not job:
                return False
            job.status = "completed"
            job.completed_at = time.time()
            job.current = job.total_chunks
            self.active.discard(job_id)

            # Update historical rate
            if job.started_at:
                duration = job.completed_at - job.started_at
                self.total_chunks_processed += job.total_chunks
                self.total_processing_time += duration

            # Move to recent, keep last 10
            self.recent.insert(0, job)
            self.recent = self.recent[:10]
            del self.jobs[job_id]

            logger.info(f"Job completed: {job_id} ({job.project})")
            await self._try_activate()
            return True

    async def fail(self, job_id: str, error: str) -> bool:
        """Mark job as failed."""
        async with self.lock:
            job = self.jobs.get(job_id)
            if not job:
                return False
            job.status = "failed"
            job.completed_at = time.time()
            job.error = error
            self.active.discard(job_id)

            self.recent.insert(0, job)
            self.recent = self.recent[:10]
            del self.jobs[job_id]

            logger.info(f"Job failed: {job_id} ({job.project}): {error}")
            await self._try_activate()
            return True

    async def cancel(self, job_id: str) -> bool:
        """Cancel a queued or active job."""
        async with self.lock:
            job = self.jobs.get(job_id)
            if not job:
                return False
            if job_id in self.queue:
                self.queue.remove(job_id)
            self.active.discard(job_id)
            del self.jobs[job_id]
            logger.info(f"Job cancelled: {job_id}")
            await self._try_activate()
            return True

    async def clear_recent(self) -> int:
        """Clear the recent jobs list. Returns count of cleared jobs."""
        async with self.lock:
            count = len(self.recent)
            self.recent.clear()
            return count

    def get_position(self, job_id: str) -> int:
        """Get queue position (0 = active, 1+ = waiting, -1 = not found)."""
        if job_id in self.active:
            return 0
        try:
            return list(self.queue).index(job_id) + 1
        except ValueError:
            return -1

    def estimate_wait_time(self, position: int, chunks_ahead: int) -> Optional[float]:
        """Estimate wait time based on historical rate."""
        if self.total_processing_time == 0:
            return None
        rate = self.total_chunks_processed / self.total_processing_time
        return chunks_ahead / rate if rate > 0 else None

    def get_status(self) -> dict:
        """Get full queue status for dashboard."""
        active_jobs = [self.jobs[jid].to_dict() for jid in self.active if jid in self.jobs]
        queued_jobs = []
        chunks_ahead = sum(j.total_chunks - j.current for j in [self.jobs.get(jid) for jid in self.active] if j)

        for i, job_id in enumerate(self.queue):
            job = self.jobs.get(job_id)
            if job:
                job_dict = job.to_dict()
                job_dict["position"] = i + 1
                job_dict["chunks_ahead"] = chunks_ahead
                job_dict["estimated_wait"] = self.estimate_wait_time(i + 1, chunks_ahead)
                queued_jobs.append(job_dict)
                chunks_ahead += job.total_chunks

        recent_jobs = [j.to_dict() for j in self.recent]

        return {
            "active": active_jobs,
            "queued": queued_jobs,
            "recent": recent_jobs,
            "workers": {
                "max": self.max_workers,
                "busy": len(self.active)
            },
            "historical_rate": round(self.total_chunks_processed / self.total_processing_time, 1) if self.total_processing_time > 0 else None
        }


# Initialize job queue (1 worker for single GPU)
job_queue = JobQueue(max_workers=1)

# Legacy indexing_progress for backward compatibility (deprecated)
indexing_progress = {
    "active": False,
    "project": None,
    "current": 0,
    "total": 0,
    "started_at": None
}

# GPU access lock - serializes requests to prevent CUDA conflicts
gpu_lock = asyncio.Lock()

# Enable PyTorch performance optimizations
torch.backends.cudnn.benchmark = True  # Auto-tune cuDNN kernels for input sizes
torch.set_float32_matmul_precision('high')  # Use TF32 precision

print("Loading NV-Embed-v2 (7B model, may take a minute)...")
model = AutoModel.from_pretrained(
    'nvidia/NV-Embed-v2',
    trust_remote_code=True,
    torch_dtype=torch.float16  # fp16 for faster inference, minimal precision loss
)
model = model.to('cuda')
model.eval()
print("Model loaded on cuda (fp16)")

# Try to compile model for faster inference (PyTorch 2.0+)
try:
    model = torch.compile(model, mode="reduce-overhead")
    print("Model compiled with torch.compile (reduce-overhead mode)")
except Exception as e:
    print(f"torch.compile not available: {e}")

# Warm-up: First inference compiles CUDA kernels (JIT) which is slow
# Do it now so first real request isn't penalized
print("Warming up CUDA kernels (this may take a while with torch.compile)...")
warmup_start = time.time()
with torch.inference_mode():
    # Multiple warm-up passes to fully compile all code paths
    for batch_size in [1, 8, 32, 64]:
        _ = model.encode(["warm up"] * batch_size, max_length=512)
    torch.cuda.synchronize()  # Ensure kernels are fully compiled
warmup_ms = (time.time() - warmup_start) * 1000
print(f"Warm-up complete ({warmup_ms:.0f}ms) - ready for requests!")


class EmbedRequest(BaseModel):
    inputs: list[str]


class ProgressUpdate(BaseModel):
    current: int
    total: int
    project: str


class JobRegisterRequest(BaseModel):
    project: str
    total_chunks: int
    instance_id: str


class JobProgressUpdate(BaseModel):
    current: int


# ============== Job Queue API (New) ==============

def _calculate_recommended_batch_size() -> int:
    """Calculate recommended batch size based on current GPU memory."""
    gpu_total_mb = torch.cuda.get_device_properties(0).total_memory / 1e6
    gpu_reserved_mb = torch.cuda.memory_reserved() / 1e6
    safety_margin_mb = 8000
    available_mb = gpu_total_mb - gpu_reserved_mb - safety_margin_mb
    mb_per_batch_item = 47  # Empirically measured

    if available_mb > 0:
        recommended = int(available_mb / mb_per_batch_item)
        return max(8, min(recommended, MAX_BATCH_SIZE))
    return 8


@app.post("/jobs")
async def register_job(request: JobRegisterRequest):
    """Register a new indexing job. Returns job_id, queue position, and recommended batch size."""
    job = await job_queue.register(
        project=request.project,
        total_chunks=request.total_chunks,
        instance_id=request.instance_id
    )
    position = job_queue.get_position(job.id)
    return {
        "job_id": job.id,
        "status": job.status,
        "position": position,
        "message": "active" if position == 0 else f"queued at position {position}",
        "recommended_batch_size": _calculate_recommended_batch_size()
    }


@app.get("/jobs")
async def list_jobs():
    """Get all jobs (active, queued, recent)."""
    return job_queue.get_status()


@app.delete("/jobs/recent")
async def clear_recent_jobs():
    """Clear the recent jobs history (dashboard admin action)."""
    count = await job_queue.clear_recent()
    return {"status": "cleared", "count": count}


@app.get("/jobs/{job_id}")
async def get_job(job_id: str):
    """Get status of a specific job."""
    # Check active/queued jobs
    if job_id in job_queue.jobs:
        job = job_queue.jobs[job_id]
        result = job.to_dict()
        result["position"] = job_queue.get_position(job_id)
        return result
    # Check recent jobs
    for job in job_queue.recent:
        if job.id == job_id:
            return job.to_dict()
    raise HTTPException(status_code=404, detail=f"Job {job_id} not found")


@app.post("/jobs/{job_id}/progress")
async def update_job_progress(job_id: str, update: JobProgressUpdate):
    """Update progress for an active job."""
    success = await job_queue.update_progress(job_id, update.current)
    if not success:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found or not active")
    return {"status": "ok"}


@app.post("/jobs/{job_id}/complete")
async def complete_job(job_id: str):
    """Mark a job as completed."""
    success = await job_queue.complete(job_id)
    if not success:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    return {"status": "completed"}


@app.post("/jobs/{job_id}/fail")
async def fail_job(job_id: str, error: str = "Unknown error"):
    """Mark a job as failed."""
    success = await job_queue.fail(job_id, error)
    if not success:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    return {"status": "failed"}


@app.delete("/jobs/{job_id}")
async def cancel_job(job_id: str):
    """Cancel a job (remove from queue or stop active)."""
    success = await job_queue.cancel(job_id)
    if not success:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    return {"status": "cancelled"}


# ============== Legacy Progress API (Deprecated - use /jobs instead) ==============

@app.post("/progress")
def update_progress(update: ProgressUpdate):
    """Update indexing progress (called by CodeCartographer)."""
    indexing_progress["active"] = True
    indexing_progress["project"] = update.project
    indexing_progress["current"] = update.current
    indexing_progress["total"] = update.total
    if indexing_progress["started_at"] is None:
        indexing_progress["started_at"] = time.time()
    return {"status": "ok"}


@app.delete("/progress")
def clear_progress():
    """Clear indexing progress (called when indexing completes)."""
    indexing_progress["active"] = False
    indexing_progress["project"] = None
    indexing_progress["current"] = 0
    indexing_progress["total"] = 0
    indexing_progress["started_at"] = None
    return {"status": "ok"}


@app.get("/progress")
def get_progress():
    """Get current indexing progress."""
    if not indexing_progress["active"]:
        return {"active": False}

    elapsed = time.time() - indexing_progress["started_at"] if indexing_progress["started_at"] else 0
    current = indexing_progress["current"]
    total = indexing_progress["total"]
    percent = (current * 100 // total) if total > 0 else 0

    # Calculate ETA
    eta = None
    if current > 0 and total > 0:
        rate = current / elapsed if elapsed > 0 else 0
        remaining = total - current
        eta = remaining / rate if rate > 0 else None

    return {
        "active": True,
        "project": indexing_progress["project"],
        "current": current,
        "total": total,
        "percent": percent,
        "elapsed_seconds": round(elapsed, 1),
        "eta_seconds": round(eta, 1) if eta else None,
        "chunks_per_second": round(current / elapsed, 1) if elapsed > 0 else 0
    }


@app.post("/embed")
async def embed(request: EmbedRequest) -> list[list[float]]:
    """Generate embeddings for a list of texts."""
    start_time = time.time()

    if not request.inputs:
        raise HTTPException(status_code=400, detail="inputs cannot be empty")

    if len(request.inputs) > MAX_BATCH_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"Batch size {len(request.inputs)} exceeds max {MAX_BATCH_SIZE}. Split into smaller batches."
        )

    # Track if we had to wait for the lock
    had_to_wait = gpu_lock.locked()
    if had_to_wait:
        stats["queue_waits"] += 1
        stats["queue_depth"] += 1
        logger.info(f"Request queued (GPU busy, depth={stats['queue_depth']}), batch size: {len(request.inputs)}")

    # Serialize GPU access to prevent CUDA conflicts
    try:
        async with gpu_lock:
            try:
                # Run the blocking GPU operation in a thread pool
                def do_embed():
                    with torch.inference_mode():  # Faster than no_grad, disables view tracking
                        embeddings = model.encode(request.inputs, max_length=MAX_LENGTH)
                        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
                        return embeddings.cpu().tolist()

                result = await asyncio.get_event_loop().run_in_executor(None, do_embed)

                # Update stats
                elapsed_ms = (time.time() - start_time) * 1000
                stats["requests"] += 1
                stats["texts_embedded"] += len(request.inputs)
                stats["total_time_ms"] += elapsed_ms

                wait_str = " (was queued)" if had_to_wait else ""
                logger.info(f"Embedded {len(request.inputs)} texts in {elapsed_ms:.1f}ms{wait_str}")

                return result

            except torch.cuda.OutOfMemoryError:
                stats["errors"] += 1
                torch.cuda.empty_cache()
                logger.error(f"OOM with batch size {len(request.inputs)}")
                raise HTTPException(
                    status_code=503,
                    detail="GPU out of memory. Try a smaller batch size."
                )
            except Exception as e:
                stats["errors"] += 1
                logger.error(f"Embedding failed: {e}")
                raise HTTPException(status_code=500, detail=str(e))
    finally:
        # Decrement queue depth when request completes (whether success or error)
        if had_to_wait:
            stats["queue_depth"] -= 1


@app.get("/health")
def health() -> dict:
    """Health check endpoint."""
    return {
        "status": "ok",
        "version": SERVER_VERSION,
        "model": "NV-Embed-v2",
        "dimensions": 4096,
        "dtype": "float16",
        "device": "cuda",
        "max_batch_size": MAX_BATCH_SIZE,
        "gpu_memory_allocated_mb": round(torch.cuda.memory_allocated() / 1e6, 1),
        "gpu_memory_reserved_mb": round(torch.cuda.memory_reserved() / 1e6, 1)
    }


@app.get("/stats")
def get_stats() -> dict:
    """Server statistics."""
    uptime = time.time() - stats["started_at"]
    avg_time = stats["total_time_ms"] / max(stats["requests"], 1)
    return {
        "version": SERVER_VERSION,
        "requests": stats["requests"],
        "texts_embedded": stats["texts_embedded"],
        "errors": stats["errors"],
        "queue_waits": stats["queue_waits"],  # Total requests that had to wait
        "queue_depth": stats["queue_depth"],  # Current requests waiting for GPU
        "avg_latency_ms": round(avg_time, 1),
        "uptime_seconds": round(uptime, 1),
        "texts_per_second": round(stats["texts_embedded"] / max(uptime, 1), 2),
        "gpu_busy": gpu_lock.locked(),
        "gpu_memory_allocated_mb": round(torch.cuda.memory_allocated() / 1e6, 1),
        "gpu_memory_reserved_mb": round(torch.cuda.memory_reserved() / 1e6, 1)
    }


@app.get("/capabilities")
def get_capabilities() -> dict:
    """Get server capabilities and recommended settings for batch sizing."""
    gpu_total_mb = torch.cuda.get_device_properties(0).total_memory / 1e6
    gpu_allocated_mb = torch.cuda.memory_allocated() / 1e6
    gpu_reserved_mb = torch.cuda.memory_reserved() / 1e6
    safety_margin_mb = 8000
    available_mb = gpu_total_mb - gpu_reserved_mb - safety_margin_mb

    recommended = _calculate_recommended_batch_size()
    # If GPU is currently busy, be more conservative
    if gpu_lock.locked():
        recommended = min(recommended, 32)

    return {
        "version": SERVER_VERSION,
        "gpu_total_mb": round(gpu_total_mb, 1),
        "gpu_allocated_mb": round(gpu_allocated_mb, 1),
        "gpu_reserved_mb": round(gpu_reserved_mb, 1),
        "gpu_available_mb": round(max(0, available_mb), 1),
        "model_memory_mb": 16000,  # NV-Embed-v2 fp16 baseline
        "max_batch_size": MAX_BATCH_SIZE,
        "recommended_batch_size": recommended,
        "gpu_busy": gpu_lock.locked()
    }


@app.get("/", response_class=HTMLResponse)
def dashboard():
    """Web dashboard for monitoring server status."""
    return """
<!DOCTYPE html>
<html>
<head>
    <title>NV-Embed-v2 Server</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
               background: #1a1a2e; color: #eee; padding: 20px; max-width: 1200px; margin: 0 auto; }
        h1 { color: #76b900; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; }
        .card { background: #16213e; border-radius: 10px; padding: 20px; }
        .card h3 { color: #888; font-size: 12px; text-transform: uppercase; margin-bottom: 8px; }
        .card .value { font-size: 28px; font-weight: bold; }
        .card .unit { font-size: 14px; color: #888; }
        .status { display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 8px; }
        .status.ok { background: #76b900; }
        .status.busy { background: #f39c12; animation: pulse 1s infinite; }
        .status.error { background: #e74c3c; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
        .progress-bar { background: #0f3460; border-radius: 5px; height: 8px; margin-top: 10px; overflow: hidden; }
        .progress-fill { background: #76b900; height: 100%; transition: width 0.3s; }
        .section { margin-top: 25px; }
        .section h2 { color: #76b900; font-size: 16px; margin-bottom: 15px; border-bottom: 1px solid #333; padding-bottom: 8px; }
        #error { background: #e74c3c; color: white; padding: 15px; border-radius: 10px; margin-bottom: 20px; display: none; }
        .footer { margin-top: 30px; color: #555; font-size: 12px; text-align: center; }

        /* Job Queue Styles */
        .job-manager { margin-bottom: 25px; }
        .job-card { background: linear-gradient(135deg, #1e3a5f 0%, #16213e 100%); border-radius: 10px; padding: 20px; margin-bottom: 15px; }
        .job-card.active { border: 2px solid #76b900; }
        .job-card.queued { border: 1px solid #f39c12; opacity: 0.8; }
        .job-card.completed { border: 1px solid #888; opacity: 0.6; }
        .job-card.failed { border: 1px solid #e74c3c; opacity: 0.7; }
        .job-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
        .job-title { font-size: 16px; font-weight: bold; }
        .job-title .job-id { color: #888; font-size: 12px; margin-left: 8px; }
        .job-status { font-size: 12px; padding: 4px 10px; border-radius: 12px; text-transform: uppercase; }
        .job-status.active { background: #76b900; color: #000; }
        .job-status.queued { background: #f39c12; color: #000; }
        .job-status.completed { background: #888; color: #fff; }
        .job-status.failed { background: #e74c3c; color: #fff; }
        .job-progress { background: #0f3460; border-radius: 8px; height: 20px; overflow: hidden; margin: 10px 0; }
        .job-progress-fill { background: linear-gradient(90deg, #76b900 0%, #9be22d 100%); height: 100%; transition: width 0.5s; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: bold; min-width: 30px; }
        .job-stats { display: flex; gap: 20px; flex-wrap: wrap; }
        .job-stat { text-align: center; min-width: 60px; }
        .job-stat .value { font-size: 16px; font-weight: bold; }
        .job-stat .label { font-size: 10px; color: #888; text-transform: uppercase; }
        .job-wait { color: #f39c12; font-size: 12px; margin-top: 8px; }
        .empty-state { color: #555; font-style: italic; padding: 20px; text-align: center; }
        .recent-list { display: flex; flex-direction: column; gap: 8px; }
        .recent-item { display: flex; justify-content: space-between; align-items: center; padding: 10px 15px; background: #16213e; border-radius: 8px; }
        .recent-item.failed { border-left: 3px solid #e74c3c; }
        .recent-item.completed { border-left: 3px solid #76b900; }
        .recent-project { font-weight: bold; }
        .recent-meta { color: #888; font-size: 12px; }
    </style>
</head>
<body>
    <h1><span class="status" id="status-dot"></span>NV-Embed-v2 Server</h1>
    <div id="error"></div>

    <!-- Job Queue Manager -->
    <div class="job-manager">
        <div class="section">
            <h2>📊 Index Job Manager</h2>
            <div id="active-jobs"></div>
            <div id="queued-jobs"></div>
        </div>

        <div class="section" id="recent-section" style="display: none;">
            <h2 style="display: flex; justify-content: space-between; align-items: center;">
                Recent Jobs
                <button onclick="clearRecent()" style="font-size: 0.5em; padding: 4px 12px; background: #666; border: none; border-radius: 4px; color: white; cursor: pointer;">Clear</button>
            </h2>
            <div id="recent-jobs" class="recent-list"></div>
        </div>
    </div>

    <!-- Server Stats -->
    <div class="grid">
        <div class="card">
            <h3>Status</h3>
            <div class="value" id="gpu-status">--</div>
        </div>
        <div class="card">
            <h3>Texts Embedded</h3>
            <div class="value" id="texts-embedded">--</div>
        </div>
        <div class="card">
            <h3>Throughput</h3>
            <div class="value" id="throughput">--</div>
            <div class="unit">texts/sec</div>
        </div>
        <div class="card">
            <h3>Avg Latency</h3>
            <div class="value" id="latency">--</div>
            <div class="unit">ms</div>
        </div>
    </div>

    <div class="section">
        <h2>GPU Memory</h2>
        <div class="grid">
            <div class="card">
                <h3>Allocated</h3>
                <div class="value" id="mem-alloc">--</div>
                <div class="progress-bar"><div class="progress-fill" id="mem-bar"></div></div>
            </div>
            <div class="card">
                <h3>Embed Queue</h3>
                <div class="value" id="queue-depth">--</div>
                <div class="unit" id="queue-waits">-- total waits</div>
            </div>
        </div>
    </div>

    <div class="section">
        <h2>Server Info</h2>
        <div class="grid">
            <div class="card">
                <h3>Version</h3>
                <div class="value" id="version">--</div>
            </div>
            <div class="card">
                <h3>Uptime</h3>
                <div class="value" id="uptime">--</div>
            </div>
            <div class="card">
                <h3>Requests</h3>
                <div class="value" id="requests">--</div>
            </div>
            <div class="card">
                <h3>Errors</h3>
                <div class="value" id="errors">--</div>
            </div>
        </div>
    </div>

    <div class="footer">Auto-refreshes every 2 seconds</div>

    <script>
        function formatTime(seconds) {
            if (!seconds) return '--';
            const h = Math.floor(seconds / 3600);
            const m = Math.floor((seconds % 3600) / 60);
            const s = Math.floor(seconds % 60);
            if (h > 0) return h + 'h ' + m + 'm';
            if (m > 0) return m + 'm ' + s + 's';
            return s + 's';
        }

        function formatNumber(n) {
            if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
            if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
            return n.toString();
        }

        function renderActiveJob(job) {
            const percent = job.percent || 0;
            return `
                <div class="job-card active">
                    <div class="job-header">
                        <div class="job-title">${job.project}<span class="job-id">#${job.id}</span></div>
                        <div style="display:flex;gap:8px;align-items:center;">
                            <span class="job-status active">Active</span>
                            <button onclick="cancelJob('${job.id}')" style="font-size:0.7em;padding:2px 8px;background:#c53030;border:none;border-radius:3px;color:white;cursor:pointer;">Cancel</button>
                        </div>
                    </div>
                    <div class="job-progress">
                        <div class="job-progress-fill" style="width: ${percent}%">${percent}%</div>
                    </div>
                    <div class="job-stats">
                        <div class="job-stat"><div class="value">${formatNumber(job.current)}</div><div class="label">Chunks</div></div>
                        <div class="job-stat"><div class="value">${formatNumber(job.total_chunks)}</div><div class="label">Total</div></div>
                        <div class="job-stat"><div class="value">${job.chunks_per_second?.toFixed(1) || '--'}</div><div class="label">Chunks/s</div></div>
                        <div class="job-stat"><div class="value">${formatTime(job.eta_seconds)}</div><div class="label">ETA</div></div>
                        <div class="job-stat"><div class="value">${formatTime(job.elapsed_seconds)}</div><div class="label">Elapsed</div></div>
                    </div>
                </div>
            `;
        }

        function renderQueuedJob(job, position) {
            return `
                <div class="job-card queued">
                    <div class="job-header">
                        <div class="job-title">${job.project}<span class="job-id">#${job.id}</span></div>
                        <div style="display:flex;gap:8px;align-items:center;">
                            <span class="job-status queued">#${position} in queue</span>
                            <button onclick="cancelJob('${job.id}')" style="font-size:0.7em;padding:2px 8px;background:#c53030;border:none;border-radius:3px;color:white;cursor:pointer;">Cancel</button>
                        </div>
                    </div>
                    <div class="job-stats">
                        <div class="job-stat"><div class="value">${formatNumber(job.total_chunks)}</div><div class="label">Chunks</div></div>
                        <div class="job-stat"><div class="value">${formatNumber(job.chunks_ahead || 0)}</div><div class="label">Ahead</div></div>
                    </div>
                    ${job.estimated_wait ? `<div class="job-wait">⏱ Estimated wait: ${formatTime(job.estimated_wait)}</div>` : ''}
                </div>
            `;
        }

        function renderRecentJob(job) {
            const icon = job.status === 'completed' ? '✓' : '✗';
            const duration = job.duration_seconds ? formatTime(job.duration_seconds) : '--';
            return `
                <div class="recent-item ${job.status}">
                    <span class="recent-project">${icon} ${job.project}</span>
                    <span class="recent-meta">${formatNumber(job.total_chunks)} chunks in ${duration}</span>
                </div>
            `;
        }

        async function clearRecent() {
            try {
                await fetch('/jobs/recent', { method: 'DELETE' });
                refresh();
            } catch (e) {
                console.error('Failed to clear recent:', e);
            }
        }

        async function cancelJob(jobId) {
            if (!confirm('Cancel this job?')) return;
            try {
                await fetch(`/jobs/${jobId}`, { method: 'DELETE' });
                refresh();
            } catch (e) {
                console.error('Failed to cancel job:', e);
            }
        }

        async function refresh() {
            try {
                const [statsRes, jobsRes] = await Promise.all([
                    fetch('/stats'),
                    fetch('/jobs')
                ]);
                const stats = await statsRes.json();
                const jobs = await jobsRes.json();

                document.getElementById('error').style.display = 'none';

                // Render active jobs
                const activeContainer = document.getElementById('active-jobs');
                if (jobs.active && jobs.active.length > 0) {
                    activeContainer.innerHTML = jobs.active.map(j => renderActiveJob(j)).join('');
                } else {
                    activeContainer.innerHTML = '<div class="empty-state">No active indexing jobs</div>';
                }

                // Render queued jobs
                const queuedContainer = document.getElementById('queued-jobs');
                if (jobs.queued && jobs.queued.length > 0) {
                    queuedContainer.innerHTML = jobs.queued.map((j, i) => renderQueuedJob(j, i + 1)).join('');
                } else {
                    queuedContainer.innerHTML = '';
                }

                // Render recent jobs
                const recentSection = document.getElementById('recent-section');
                const recentContainer = document.getElementById('recent-jobs');
                if (jobs.recent && jobs.recent.length > 0) {
                    recentSection.style.display = 'block';
                    recentContainer.innerHTML = jobs.recent.slice(0, 5).map(j => renderRecentJob(j)).join('');
                } else {
                    recentSection.style.display = 'none';
                }

                // Status indicator
                const dot = document.getElementById('status-dot');
                const statusText = document.getElementById('gpu-status');
                if (jobs.active && jobs.active.length > 0) {
                    dot.className = 'status busy';
                    statusText.textContent = 'Indexing';
                } else if (stats.gpu_busy) {
                    dot.className = 'status busy';
                    statusText.textContent = 'Processing';
                } else {
                    dot.className = 'status ok';
                    statusText.textContent = 'Ready';
                }

                // Server stats
                document.getElementById('texts-embedded').textContent = formatNumber(stats.texts_embedded);
                document.getElementById('throughput').textContent = stats.texts_per_second.toFixed(1);
                document.getElementById('latency').textContent = stats.avg_latency_ms.toFixed(0);
                document.getElementById('version').textContent = 'v' + stats.version;
                document.getElementById('uptime').textContent = formatTime(stats.uptime_seconds);
                document.getElementById('requests').textContent = formatNumber(stats.requests);
                document.getElementById('errors').textContent = stats.errors;

                // Memory
                const memPct = (stats.gpu_memory_allocated_mb / 128000) * 100;
                document.getElementById('mem-alloc').textContent = (stats.gpu_memory_allocated_mb / 1000).toFixed(1) + ' GB';
                document.getElementById('mem-bar').style.width = memPct + '%';

                // Embed queue
                document.getElementById('queue-depth').textContent = stats.queue_depth;
                document.getElementById('queue-waits').textContent = stats.queue_waits + ' total waits';

            } catch (e) {
                document.getElementById('error').textContent = 'Connection lost: ' + e.message;
                document.getElementById('error').style.display = 'block';
                document.getElementById('status-dot').className = 'status error';
            }
        }

        refresh();
        setInterval(refresh, 2000);
    </script>
</body>
</html>
"""
