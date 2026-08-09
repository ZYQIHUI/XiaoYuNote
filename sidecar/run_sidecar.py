"""PyInstaller 打包入口 — 等价于 `python -m sidecar`。"""

import sys
from pathlib import Path

# 无论从源码还是打包目录运行，都确保 sidecar/kb 可导入
sys.path.insert(0, str(Path(__file__).resolve().parent))

from sidecar.server import main

if __name__ == "__main__":
    main()
