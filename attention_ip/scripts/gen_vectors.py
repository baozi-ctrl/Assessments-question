# -*- coding: utf-8 -*-
# run_sim.ps1 的辅助：在 sim 目录生成 vectors.txt
# 用法: python scripts/gen_vectors.py，输出 ../sim/vectors.txt
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from golden_model import main as gm

if __name__ == "__main__":
    sim_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "sim"))
    os.chdir(sim_dir)
    gm()