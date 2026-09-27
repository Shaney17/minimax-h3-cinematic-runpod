#!/usr/bin/env bash
# Capture ComfyUI startup errors so a failed Runpod job can report the cause.
exec > >(tee /tmp/h3-worker.log) 2>&1
exec /start.sh
