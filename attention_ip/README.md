# Attention 加速器 RTL IP 原型

数字组招生实践（大二）考核项目。实现固定规模 `S=8, d=4` 的 Attention 硬件加速器 RTL IP 原型，
输入 Q/K/V 为 8-bit 有符号整数，输出 O 为 8-bit 有符号整数。

---

## 1. 文件结构

```
attention_ip/
├── rtl/
│   └── attention_ip.v        # RTL 主模块（可综合）
├── tb/
│   └── tb_attention_ip.v     # 自检 testbench（读 vectors.txt，逐项比对）
├── scripts/
│   ├── golden_model.py       # Python 参考模型 + 指数 LUT
│   ├── gen_vectors.py        # 生成 44 组测试向量 → sim/vectors.txt
│   ├── demo_vector.py        # 现场演示：生成 1 组输入并打印数据小抄
│   ├── run_sim.bat           # 一键仿真：生成向量 → 编译 → 运行（标准 44 组）
│   └── run_demo.bat          # 快速演示：只运行不编译（可带随机种子参数）
├── sim/
│   ├── vectors.txt           # 测试向量（标准 44 组 / 演示 1 组）
│   ├── attention_ip.vcd      # 仿真波形（GTKWave 查看）
│   └── attention_ip.tb.vvp   # 编译产物（由 run_sim 自动生成）
└── doc/
    ├── 设计报告.docx         # 完整设计报告
    ├── 答辩文案.docx         # 答辩讲稿与必背速查卡
    └── 新汇报PPT.pptx        # 汇报 PPT
```

各目录作用：

| 目录 | 内容 |
|------|------|
| `rtl/` | 待综合的 RTL 源码 |
| `tb/` | 测试 testbench（仅仿真用，不可综合） |
| `scripts/` | Python 参考模型、测试向量生成、仿真脚本 |
| `sim/` | 仿真产物（向量、波形、结果） |
| `doc/` | 报告、PPT 与答辩资料 |

---

## 2. 运行命令

### 2.1 标准仿真（44 组向量）

在项目根目录双击或运行：

```bat
scripts\run_sim.bat
```

脚本按顺序执行：`python scripts\gen_vectors.py`（生成 44 组测试向量）→ `iverilog`（编译 RTL+TB）
→ `vvp`（仿真自检），最后打印比对结果。

### 2.2 现场演示（1 组随机输入）

```bat
scripts\run_demo.bat 7   rem 7 为随机种子，可换任意数字
```

不重新编译，直接运行并打印 Q/K/V、score/x_max/weight/L/ACC 及比对结果。

### 2.3 手动步骤

```bat
python scripts\gen_vectors.py
iverilog -g2012 -o sim\attention_ip.tb.vvp rtl\attention_ip.v tb\tb_attention_ip.v
cd sim && vvp attention_ip.tb.vvp
```

### 2.4 查看波形

用 GTKWave 打开 `sim\attention_ip.vcd`，可选看任意内部信号（score / x_max / weight / FSM state 等）。

---

## 3. 工具版本

| 工具 | 版本 | 用途 |
|------|------|------|
| Icarus Verilog | 12.0 (devel) | 编译与仿真（`iverilog` / `vvp`） |
| GTKWave | 随 iverilog 附带 | 查看波形 |
| Python | 3.13 | 运行参考模型 / 生成测试向量 |
