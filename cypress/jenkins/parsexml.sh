#!/bin/bash

set -x

pip3 install beautifulsoup4 requests
python3 parse.py

echo "PYTHON EXEC WORKED"
exit 0