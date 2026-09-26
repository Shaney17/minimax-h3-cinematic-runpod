"""Make a deployable UI copy of the supplied MiniMax H3 Cinematic workflow."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


UPSCALE_MODEL = "minimax_h3_latent_upscaler_3d_conv_v1_fp32.pth"
UNUSED_NODE_IDS = {167, 187}  # Unconnected Ref2VA checkpoint and style LoRA.


def prepare(source: Path, destination: Path) -> None:
    data = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "nodes" not in data or "links" not in data:
        raise ValueError("Expected a ComfyUI UI workflow JSON")

    retained_links = [
        link
        for link in data["links"]
        if link[1] not in UNUSED_NODE_IDS and link[3] not in UNUSED_NODE_IDS
    ]
    retained_link_ids = {link[0] for link in retained_links}
    nodes = []
    found_upscaler = False
    for node in data["nodes"]:
        if node["id"] in UNUSED_NODE_IDS:
            continue
        if node["type"] == "MinimaxH3LatentUpscaler3D":
            node["widgets_values"][0] = UPSCALE_MODEL
            found_upscaler = True
        values = node.get("widgets_values")
        if isinstance(values, dict):
            values.pop("videopreview", None)
        for output in node.get("outputs", []):
            if isinstance(output.get("links"), list):
                output["links"] = [
                    link_id for link_id in output["links"]
                    if link_id in retained_link_ids
                ]
        nodes.append(node)

    if not found_upscaler:
        raise ValueError("Upscaler node not found")

    data["nodes"] = nodes
    data["links"] = retained_links
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.destination)
