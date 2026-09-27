# MiniMax H3 Cinematic on Runpod Serverless

This repository builds a dedicated queue worker for the supplied MiniMax H3
Cinematic ComfyUI workflow. It is separate from the Qwen Image endpoint.

## Local request interface

Run the included interface with Python 3.10 or newer; no packages are required:

```bash
python3 web_ui.py
```

Open `http://127.0.0.1:8765` and provide:

1. A Runpod API key. It stays in the browser tab and is forwarded by the local
   server to the fixed endpoint `xjh0wwhkto13ky`; it is not written to disk.
2. The prompt. The UI preloads the original story from node 190 in the included
   workflow. You can edit it; the request replaces that node's `value` input.
3. The three reference images for LoadImage nodes 28 (subject 1), 29 (subject 2),
   and 30 (environment). The interface uploads them as Base64 files and updates
   those node filenames automatically.

The interface loads `workflow/cinematic_api.json` automatically. This API graph
was converted from the supplied UI graph, then reduced to its Stage 2 output and
three image references. It passed static link checks, but has **not yet passed
runtime validation**: on 2026-09-27 a smoke job failed before workflow validation
because ComfyUI inside endpoint `xjh0wwhkto13ky` was not reachable on port 8188.
Inspect and fix worker startup before relying on this graph for production jobs.

Click **Gửi request**. The interface submits an asynchronous job, checks its
status, and displays a returned MP4 or S3 URL. Each request has a 20-minute
execution timeout and a 1-hour total TTL. Keep the browser tab open while the
job is processing, or save the Job ID to check it in Runpod.

The current worker supports image uploads only. The bundled API graph disconnects
the video and audio reference branches from MiniMax H3. A request over
9.5 MB is stopped locally with a message to reduce image file size. For an MP4
larger than 8 MB, configure the worker's S3 output settings as described below.

The interface binds to `127.0.0.1` only. It does not host a public website or
store your API key, images, workflow, or generated video on the local server.

## What is included

- Official `runpod/worker-comfyui:5.10.0-base` worker, upgraded to ComfyUI v0.37.0.
- The custom nodes used by the workflow, including KJNodes, VideoHelperSuite,
  Easy Use, the MiniMax H3 latent upscaler, and UniBlockSwap.
- The model files used by the connected generation path. Weights are downloaded
  during the image build; they are not committed to GitHub.
- A video-aware handler. The upstream worker handles images, but does not return
  MP4 files from `VHS_VideoCombine` or `SaveVideo`.
- `workflow/cinematic_ui.json` for editing, and `workflow/cinematic_api.json`
  for the image-only API path.

## Important input and output details

The editable `cinematic_ui.json` is a ComfyUI UI graph; the local interface
sends `cinematic_api.json` as `input.workflow` in each Runpod request. The
original graph references three input PNGs and media-reference nodes. The JSON
alone does not contain those files. The local interface handles the three images;
video/audio references are not part of this API variant.

The handler returns an MP4 as base64 only when its file is at most 8 MB. For
larger videos, configure Runpod's S3 output settings (`BUCKET_ENDPOINT_URL`,
`BUCKET_ACCESS_KEY_ID`, `BUCKET_SECRET_ACCESS_KEY`, `BUCKET_REGION`) so the API
returns an object-storage URL. It prefers the final `H3_Stage2` video.

## Deployment settings

- Queue endpoint; one worker maximum and zero minimum while validating.
- GPU: start with an 80 GB class. The 48 GB class is not yet verified for this
  two-pass 1.5 MP workflow.
- Container disk: at least 80 GB. The eight selected weights total about 43 GB,
  before the ComfyUI runtime and temporary files.
- Job timeout: at least 20 minutes for a first real render.
- Image source: GitHub integration pointed at this repository's `Dockerfile`.

## Model sources

The exact download URLs and destinations are in `Dockerfile`. The large
checkpoints are from Comfy-Org, smhfacct, LBH-123-AI, and TenStrip on Hugging
Face. The Mystic and Cinema LoRAs are mirrored by Serenak and aronzhan.

## Local checks

```bash
python3 prepare_workflow.py "/path/to/Minimax H3 Cinematic Version.json" workflow/cinematic_ui.json
python3 -m py_compile handler.py prepare_workflow.py
docker build --platform=linux/amd64 -t minimax-h3-cinematic:local .
```
