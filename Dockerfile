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

WORKDIR /
RUN cp /handler.py /handler_base.py
COPY handler.py /handler.py
COPY workflow/cinematic_ui.json /workflows/cinematic_ui.json
COPY start_h3.sh /start_h3.sh
RUN chmod 755 /start_h3.sh
ENV COMFY_LOG_LEVEL=INFO
CMD ["/start_h3.sh"]
