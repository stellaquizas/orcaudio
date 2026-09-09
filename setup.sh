#!/bin/zsh
set -eu
cd "${0:A:h}"
uv venv --python 3.11 .venv
uv pip sync --python .venv/bin/python requirements.lock
print 'Environment ready. Download a model manually in Orcaudio Settings'
