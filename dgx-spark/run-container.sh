#!/bin/bash
# Run the NGC PyTorch container with GPU support and persistent cache
#
# Usage: ./run-container.sh
#
# Prerequisites:
#   1. Login to NGC first: docker login nvcr.io
#      Username: $oauthtoken
#      Password: <your-api-key>

docker run -it --runtime=nvidia --gpus=all \
    -p 8080:8080 \
    -v $HOME/.cache/huggingface:/root/.cache/huggingface \
    -v $(pwd):/workspace/dgx-spark \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    nvcr.io/nvidia/pytorch:25.10-py3
