"""Runpod ComfyUI handler with MP4 output support for MiniMax H3."""

from __future__ import annotations

import base64
import os
import time
from pathlib import Path

import runpod

import handler_base


OUTPUT_DIR = Path(os.environ.get("H3_OUTPUT_DIR", "/comfyui/output"))
MAX_INLINE_VIDEO_BYTES = int(os.environ.get("H3_MAX_INLINE_VIDEO_BYTES", "8000000"))
VIDEO_SUFFIXES = {".mp4", ".webm", ".mov", ".mkv"}
STARTUP_LOG = Path("/tmp/h3-worker.log")


def _video_snapshot() -> dict[str, tuple[int, int]]:
    if not OUTPUT_DIR.exists():
        return {}
    return {
        str(path): (path.stat().st_mtime_ns, path.stat().st_size)
        for path in OUTPUT_DIR.rglob("*")
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES
    }


def _new_videos(before: dict[str, tuple[int, int]]) -> list[Path]:
    changed = []
    for name, state in _video_snapshot().items():
        if before.get(name) != state:
            changed.append(Path(name))
    # Stage 2 is the final render in the supplied workflow.
    stage2 = [p for p in changed if p.name.startswith("H3_Stage2")]
    return sorted(stage2 or changed, key=lambda p: p.stat().st_mtime_ns)


def _encode_video(path: Path, job_id: str) -> dict:
    if os.environ.get("BUCKET_ENDPOINT_URL"):
        url = handler_base.rp_upload.upload_image(job_id, str(path))
        return {"filename": path.name, "type": "s3_url", "data": url}

    size = path.stat().st_size
    if size > MAX_INLINE_VIDEO_BYTES:
        raise ValueError(
            f"Video {path.name} is {size} bytes; configure the Runpod S3 output "
            "environment variables before requesting videos this large."
        )
    return {
        "filename": path.name,
        "type": "base64",
        "data": base64.b64encode(path.read_bytes()).decode("ascii"),
    }


def handler(job: dict) -> dict:
    before = _video_snapshot()
    result = handler_base.handler(job)

    if isinstance(result, dict) and "not reachable" in str(result.get("error", "")).lower():
        try:
            result["startup_log_tail"] = STARTUP_LOG.read_text(errors="replace")[-12000:]
        except OSError as exc:
            result["startup_log_tail"] = f"Không đọc được log khởi động: {exc}"

    details = result.get("details", []) if isinstance(result, dict) else []
    if any("Workflow execution error" in str(x) for x in details):
        return result
    if isinstance(result, dict) and result.get("error") not in (None, "Job processing failed"):
        return result

    videos = _new_videos(before)
    if not videos:
        return result

    try:
        encoded = [_encode_video(path, job["id"]) for path in videos]
    except Exception as exc:
        return {"error": str(exc)}

    output = {"videos": encoded}
    if isinstance(result, dict) and result.get("images"):
        output["images"] = result["images"]
    return output


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
