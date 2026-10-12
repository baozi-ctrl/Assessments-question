# -*- coding: utf-8 -*-
# 答辩现场演示用：把一组自定义输入写进 sim/vectors.txt（只含这一组），
# 再跑 vvp 即可验证这组输入；此时波形文件里也只有这一次任务，最好讲。
#
# 用法 1: python scripts/demo_vector.py      -> 使用下面手改的 Q/K/V
# 用法 2: python scripts/demo_vector.py 7    -> 用随机种子 7 现场随机生成一组
# 演示完恢复标准 44 组: 双击 scripts/run_sim.bat
import os, sys, random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import attention

# ====== 现场演示就改这三块（每个数都写在 -128..127 之间） ======
Q = [1, 11, 19, 5]
K = [
    [  1,   2,   3,   4],
    [  0,   0,   0,   0],
    [ -1,  -1,  -1,  -1],
    [4, 3, 2, 1],
    [ 10,  20,  30,  40],
    [-50,  60, -70,  80],
    [  1,   0,  -1,   0],
    [ 33,  33,  33,  33],
]
V = [
    [1, 1, 1, 1],
    [2, 2, 2, 2],
    [3, 3, 3, 3],
    [4, 4, 4, 4],
    [5, 5, 5, 5],
    [6, 6, 6, 6],
    [7, 7, 7, 7],
    [8, 8, 8, 8],
]
# =============================================================

def c8(x):
    return max(-128, min(127, x))

def main():
    if len(sys.argv) > 1:
        try:
            seed = int(sys.argv[1])
        except ValueError:
            print("参数应为整数随机种子, 如: python scripts/demo_vector.py 7")
            return
        rng = random.Random(seed)
        q_use = [[rng.randint(-128, 127) for _ in range(4)],
                 [[rng.randint(-128, 127) for _ in range(4)] for _ in range(8)],
                 [[rng.randint(-128, 127) for _ in range(4)] for _ in range(8)]]
        print("随机输入 seed = %d" % seed)
    else:
        q_use = [Q, K, V]

    q_use = [[c8(x) for x in q_use[0]],
             [[c8(x) for x in row] for row in q_use[1]],
             [[c8(x) for x in row] for row in q_use[2]]]

    o, scores, w, L, acc = attention(q_use[0], q_use[1], q_use[2])

    nums = list(q_use[0]) + [x for row in q_use[1] for x in row] \
         + [x for row in q_use[2] for x in row] + list(o)
    sim_dir = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "sim"))
    with open(os.path.join(sim_dir, "vectors.txt"), "w") as f:
        f.write(" ".join(map(str, nums)) + "\n")

    print("=" * 46)
    print("已写入 1 组自定义向量 -> sim\\vectors.txt")
    print("-" * 46)
    print("Q      =", q_use[0])
    print("K      = [")
    for row in q_use[1]:
        print("          ", row)
    print("         ]")
    print("V      = [")
    for row in q_use[2]:
        print("          ", row)
    print("         ]")
    print("-" * 46)
    print("score  =", scores)
    print("x_max  =", max(scores))
    print("weight =", w)
    print("L      =", L)
    print("ACC    =", acc)
    print("期望 O =", o, "  <- 波形 out_data 应逐个等于它")
    print("-" * 46)
    print("下一步(在工程根目录):")
    print("  1) cd sim")
    print("  2) vvp attention_ip.tb.vvp     看 ALL PASS 和延迟")
    print("  3) gtkwave attention_ip.vcd    对着上面打印的数讲波形")
    print("演示完: 回根目录跑 scripts\\run_sim.bat 恢复标准 44 组")

if __name__ == "__main__":
    main()
