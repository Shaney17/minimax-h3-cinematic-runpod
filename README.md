# MiniMax H3 Cinematic on Runpod Serverless

This repository builds a dedicated queue worker for the supplied MiniMax H3
Cinematic ComfyUI workflow. It is separate from the Qwen Image endpoint.

## What is included

- Official `runpod/worker-comfyui:5.10.0-base` worker, upgraded to ComfyUI v0.37.0.
- The custom nodes used by the workflow, including KJNodes, VideoHelperSuite,
  Easy Use, the MiniMax H3 latent upscaler, and UniBlockSwap.
- The model files used by the connected generation path. Weights are downloaded
  during the image build; they are not committed to GitHub.
- A video-aware handler. The upstream worker handles images, but does not return
  MP4 files from `VHS_VideoCombine` or `SaveVideo`.
- `workflow/cinematic_ui.json`, with the obsolete upscaler filename corrected.

## Important input and output details

The included workflow is a **ComfyUI UI graph**. For API calls, open it in the
deployed ComfyUI version and export **Workflow > Export (API)**. Send the exported
object as `input.workflow` to the Runpod endpoint. The original graph references
three input PNGs and has media-reference nodes; provide the corresponding files
and update those node inputs before requesting generation. The JSON alone does
not contain those media files.

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
