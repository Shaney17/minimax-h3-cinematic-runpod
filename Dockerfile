# Hotfix: reuse the last successful image with all MiniMax H3 model weights.
# The full build recipe remains available in Git history at commit ecdd29fa6.
FROM registry.runpod.net/shaney17-minimax-h3-cinematic-runpod-main-dockerfile:ecdd29fa6

WORKDIR /
COPY handler.py /handler.py
COPY start_h3.sh /start_h3.sh
COPY workflow/cinematic_api.json /workflows/cinematic_api.json
COPY workflow/cinematic_ui.json /workflows/cinematic_ui.json

# ComfyUI v0.37 forces Comfy Kitchen INT8 attention in the quantized H3 video
# VAE decoder, independent of ModelAttentionBackend. The prebuilt kernel fails
# on this Runpod CUDA driver; PyTorch SDPA accepts the same Q/K/V tensors.
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
RUN python -m py_compile /comfyui/comfy/ldm/minimax/vae.py /handler.py && chmod 755 /start_h3.sh

ENV COMFY_LOG_LEVEL=INFO
CMD ["/start_h3.sh"]
