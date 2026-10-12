# -*- coding: utf-8 -*-
"""
Attention RTL IP 的 Python Golden Model
=========================================
规模固定为 S=8, d=4, Batch/Head=1/1。
输入 Q:[1,4], K:[8,4], V:[8,4] 均为 8-bit 有符号整数。
输出 O:[1,4]，每个元素为 8-bit 有符号整数，由 round(ACC/L) 得到。

与 RTL 完全一致的定点约定：
  - 输入 Q/K/V: 8-bit 有符号
  - Score      : 8 个有符号点积
  - x_max      : Score 的最大值
  - weight     : 无符号定点，小数固定 4 位。W = round(exp(-m)*16)，其中 m = x_max - score >= 0
  - L          : sum over j of W_j          (整数，单位 1/16)
  - ACC        : sum over j of W_j * V_j    (整数，因 1/16 相消)
  - O[i]       : round(ACC[i]/L)            (round-half-up，有符号)
"""
import math
import random

# ---------- 常量 ----------
S = 8      # Token 数
D = 4      # Head 维度
LUT_SIZE   = 32   # 指数查找表大小（地址由 m 截断得到）
QFRAC      = 4    # weight 小数位（固定 4 位）


def make_lut():
    """生成指数查找表：W(m) = round(exp(-m) * 2^QFRAC)，m=0..LUT_SIZE-1。"""
    lut = []
    for m in range(LUT_SIZE):
        v = math.exp(-m) * (1 << QFRAC)
        lut.append(int(math.floor(v + 0.5)))   # round-half-up
    return lut


LUT = make_lut()


def exp_lut_lookup(m):
    """按 RTL 规则查表：m 截断到 [0, LUT_SIZE-1]。"""
    if m > LUT_SIZE - 1:
        m = LUT_SIZE - 1
    if m < 0:
        m = 0
    return LUT[m]


def round_div(num, den):
    """round-half-up：frac>=0.5 进一，返回有符号整数。den>0。"""
    q = abs(num) // den
    r = abs(num) % den
    if 2 * r >= den:
        q += 1
    return q if num >= 0 else -q


def attention(q, k, v):
    """纯软件参考模型，返回 4 元素 O（已按 8-bit 有符号钳位）。"""
    # 1) Score
    scores = []
    for j in range(S):
        s = sum(int(q[k_]) * int(k[j][k_]) for k_ in range(D))
        scores.append(s)
    # 2) x_max
    x_max = max(scores)
    # 3) weight / L
    w = [exp_lut_lookup(x_max - scores[j]) for j in range(S)]
    L = sum(w)
    assert L > 0, "L 必须 > 0（x_max 对应 weight=exp(0)<<QFRAC>0）"
    # 4) ACC
    acc = [sum(int(w[j]) * int(v[j][d_]) for j in range(S)) for d_ in range(D)]
    # 5) O = round(ACC/L)，钳位到 8-bit 有符号
    o = [round_div(acc[d_], L) for d_ in range(D)]
    o = [max(-128, min(127, x)) for x in o]
    return o, scores, w, L, acc


# ---------- 测试向量生成 ----------
def gen_vector(seed, low=-128, high=127):
    """用可复现的伪随机（LFSR/线性同余）生成一组 Q/K/V。"""
    rng = random.Random(seed)
    q = [rng.randint(low, high) for _ in range(D)]
    k = [[rng.randint(low, high) for _ in range(D)] for _ in range(S)]
    v = [[rng.randint(low, high) for _ in range(D)] for _ in range(S)]
    return q, k, v


def vec_to_line(q, k, v, o):
    """序列化成单行：q(4) k(32) v(32) o(4)。"""
    nums = list(map(str, q))
    for row in k:
        nums += list(map(str, row))
    for row in v:
        nums += list(map(str, row))
    nums += list(map(str, o))
    return " ".join(nums)


def main():
    random.seed(2026)
    lines = []
    # 定向用例 0：全部为零；Q 有值 K/V 为 0
    q0 = [0, 0, 0, 0]; k0 = [[0] * D for _ in range(S)]; v0 = [[0] * D for _ in range(S)]
    o0, *_ = attention(q0, k0, v0)
    lines.append(vec_to_line(q0, k0, v0, o0))
    # 定向用例 1：K0=V0 突出，其余 V=0（检验 Softmax 加权只保留匹配项）
    q1 = [1, 0, 0, 0]
    k1 = [[1, 0, 0, 0], [0] * D] + [[0] * D] * 6
    v1 = [[100, -100, 50, -50], [0] * D] + [[1] * D] * 6
    o1, *_ = attention(q1, k1, v1)
    lines.append(vec_to_line(q1, k1, v1, o1))
    # 定向用例 2：所有 K、V 相同（Softmax 归一化后应回到该 V 本身）
    q2 = [5, -3, 2, 7]
    k2 = [[1, 2, 3, 4]] * S
    v2 = [[9, -9, 64, -64]] * S
    o2, *_ = attention(q2, k2, v2)
    lines.append(vec_to_line(q2, k2, v2, o2))
    # 定向用例 3：负输入大动态范围（检验符号与钳位）
    q3 = [-8, 6, -4, 2]; k3 = [[-11] * D for _ in range(S)]; v3 = [[9] * D for _ in range(S)]
    o3, *_ = attention(q3, k3, v3)
    lines.append(vec_to_line(q3, k3, v3, o3))
    # 随机用例 40 组
    for seed in range(4, 4 + 40):
        q, k, v = gen_vector(seed)
        o, *_ = attention(q, k, v)
        lines.append(vec_to_line(q, k, v, o))

    out_path = "vectors.txt"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"[golden] 生成 {len(lines)} 组测试向量 -> {out_path}")
    print("[golden] 指数 LUT (m->W):", LUT[:8], "...(m>=4 均为 0)")


if __name__ == "__main__":
    main()