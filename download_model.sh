#!/bin/bash

# Configuration
REPO_ID="argmaxinc/whisperkit-coreml"
TARGET_DIR="$HOME/Library/Application Support/MacSpeechToText/Models"

# Default Model
DEFAULT_MODEL="openai_whisper-large-v3"
MODEL_NAME=${1:-$DEFAULT_MODEL}

echo "=========================================="
echo "    MacSpeechToText Model Downloader"
echo "=========================================="
echo "Starting download for model: $MODEL_NAME"
echo "Target Directory: $TARGET_DIR"

# 1. Dependency Check
if ! command -v hf &> /dev/null; then
    echo "This script requires 'huggingface-cli' (part of 'huggingface_hub' python package)."
    read -p "Do you want to install it using pip? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pip install -U "huggingface_hub[cli]"
    else
        echo "Please install huggingface-cli manually: pip install huggingface_hub[cli]"
        exit 1
    fi
fi

# 2. Setup Directory
mkdir -p "$TARGET_DIR"

# 3. Download
echo "Downloading model files... (This may take a while depending on network)"
echo "Downloading from: $REPO_ID"

# We use huggingface-cli download with include filter to get only the specific model folder
# We download to a temporary location first to handle the folder structure correctly if needed,
# or direct to target.
# Structure in repo: <model_name>/<files>
# We want: <TARGET_DIR>/<model_name>/<files>

# The command will download into TARGET_DIR, maintainingRepo structure (so creating the model folder inside)
hf download $REPO_ID \
    --include "$MODEL_NAME/*" \
    --local-dir "$TARGET_DIR"

# Check for tokenizer.json in the downloaded folder
# TARGET_MODEL_DIR="$TARGET_DIR/$MODEL_NAME"
# if [ ! -f "$TARGET_MODEL_DIR/tokenizer.json" ]; then
#     echo "tokenizer.json not found in model folder. Attempting to download from repo root..."
#     hf download $REPO_ID \
#         --include "tokenizer.json" \
#         --local-dir "$TARGET_MODEL_DIR"
# fi

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "=========================================="
    echo "Download Complete!"
    echo "Model installed at: $TARGET_DIR/$MODEL_NAME"
    echo "You can now select '$MODEL_NAME' in the MacSpeechToText settings."
    echo "=========================================="
else
    echo "Download Failed. Please check the model name and your internet connection."
    exit $EXIT_CODE
fi
