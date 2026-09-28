# Trigger Runpod rebuild with ComfyUI startup diagnostics.
FROM runpod/worker-comfyui:5.10.0-base

ENV PYTHONUNBUFFERED=1
WORKDIR /comfyui

# MiniMax H3 native nodes require a recent ComfyUI. Keep CUDA/PyTorch from the worker base.
RUN git fetch --depth 1 origin v0.37.0 \
    && git checkout --detach FETCH_HEAD \
    && uv pip install -r /comfyui/requirements.txt \
    && uv pip install 'transformers>=4.50.3,<5' 'huggingface-hub<1.0'

# The UI workflow uses KJ Get/Set, VideoHelperSuite, Easy Use, and the H3 upscaler.
# UniBlockSwap is currently bypassed but is installed so the original graph still opens.
RUN comfy-node-install \
    https://github.com/kijai/ComfyUI-KJNodes \
    https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite \
    https://github.com/rgthree/rgthree-comfy \
    https://github.com/yolain/ComfyUI-Easy-Use \
    https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler \
    https://github.com/smthemex/ComfyUI_UniBlockSwap

# Smallest active model set in the supplied Cinematic workflow. The disconnected
# Ref2VA checkpoint and disconnected Chinese LoRA are intentionally omitted.
RUN comfy model download --url https://huggingface.co/smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models/resolve/main/minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors --relative-path models/diffusion_models --filename minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors
RUN comfy model download --url https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors --relative-path models/text_encoders --filename qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
RUN comfy model download --url https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_int8_convrot.safetensors --relative-path models/vae --filename minimax_h3_video_vae_int8_convrot.safetensors \
    && comfy model download --url https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors --relative-path models/vae --filename minimax_h3_audio_vae_fp32.safetensors
RUN comfy model download --url https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler/resolve/main/minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_fp32.pth --relative-path models/latent_upscale_models --filename minimax_h3_latent_upscaler_3d_conv_v1_fp32.pth
RUN comfy model download --url https://huggingface.co/TenStrip/MinimaxH3-Turbo_Shenanigans/resolve/main/lightx2v_hybrid-4to8step-Turbo_r48.safetensors --relative-path models/loras --filename lightx2v_hybrid-4to8step-Turbo_r48.safetensors \
    && comfy model download --url https://huggingface.co/Serenak/chilloutmix/resolve/main/MysticXXX_MMH3-V1.safetensors --relative-path models/loras --filename MysticXXX_MMH3-V1.safetensors \
    && comfy model download --url https://huggingface.co/buckets/aronzhan/H3-Loras-bucket/resolve/Cinema-MH3-V02_000010000.safetensors --relative-path models/loras --filename Cinema-MH3-V02_000010000.safetensors

# Fail the image build if a CDN served an error page or a truncated file.
RUN python - <<'PY'
from pathlib import Path
minimums = {
    'diffusion_models/minimax_h3_hybrid_fl2va_ref2va_b25-49-int8.safetensors': 20_000_000_000,
    'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors': 15_000_000_000,
    'vae/minimax_h3_video_vae_int8_convrot.safetensors': 2_700_000_000,
    'vae/minimax_h3_audio_vae_fp32.safetensors': 600_000_000,
    'latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_fp32.pth': 1_300_000_000,
    'loras/lightx2v_hybrid-4to8step-Turbo_r48.safetensors': 900_000_000,
    'loras/MysticXXX_MMH3-V1.safetensors': 550_000_000,
    'loras/Cinema-MH3-V02_000010000.safetensors': 140_000_000,
}
for rel, minimum in minimums.items():
    path = Path('/comfyui/models') / rel
    actual = path.stat().st_size
    if actual < minimum:
        raise RuntimeError(f'{rel}: expected at least {minimum} bytes, got {actual}')
    print(rel, actual)
PY

# The base worker starts with /opt/venv/bin/python. Comfy CLI also creates
# /comfyui/.venv, so target the runtime interpreter explicitly here.
RUN uv pip install --python /opt/venv/bin/python -r /comfyui/requirements.txt \
    && for req in /comfyui/custom_nodes/*/requirements.txt; do \
         if [ -f "$req" ]; then uv pip install --python /opt/venv/bin/python -r "$req"; fi; \
       done \
    && uv pip install --python /opt/venv/bin/python 'transformers>=4.50.3,<5' 'huggingface-hub<1.0' \
    && /opt/venv/bin/python -c "import comfy_aimdo.storage"

WORKDIR /
RUN cp /handler.py /handler_base.py
COPY handler.py /handler.py
COPY workflow/cinematic_ui.json /workflows/cinematic_ui.json
COPY workflow/cinematic_api.json /workflows/cinematic_api.json
COPY start_h3.sh /start_h3.sh
RUN chmod 755 /start_h3.sh
# Use PyTorch SDPA in the quantized H3 video VAE decoder. ComfyUI v0.37
# otherwise invokes a Comfy Kitchen INT8 kernel that fails on this CUDA driver.
RUN python - <<'PY'
import json
from pathlib import Path

vae = Path('/comfyui/comfy/ldm/minimax/vae.py')
source = vae.read_text()
old = 'out = comfy.quant_ops.ck.int8_attention(query, key, value)'
new = 'out = torch.nn.functional.scaled_dot_product_attention(query, key, value)'
if source.count(old) != 1:
    raise RuntimeError('MiniMax H3 VAE attention call changed; review this hotfix')
vae.write_text(source.replace(old, new))

workflow_path = Path('/workflows/cinematic_api.json')
workflow = json.loads(workflow_path.read_text())
workflow['120']['inputs']['attention'] = 'pytorch attention'
workflow_path.write_text(json.dumps(workflow, ensure_ascii=False, indent=2))
PY
RUN python -m py_compile /comfyui/comfy/ldm/minimax/vae.py

ENV COMFY_LOG_LEVEL=INFO
CMD ["/start_h3.sh"]
