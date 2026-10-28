# LoCoMo test 评测结果汇总

- 数据：LoCoMo test split，7 个对话（conv-26/30/41/42/48/49/50），共 1085 个 QA。
- 所有 run 的 memory manager 都是 `ahmedehabb/Memory-R2`，不同的只有 answer agent 和它的推理精度/长度。
- 指标都乘了 100。F1 和 BLEU-1 是 token 级分数按题取平均；LLM judge 是 gpt-4o-mini 判为 CORRECT 的比例。
- 来源：`/gpfs/radev/home/wf287/scratch/memory_r2/results/`，日志在 `.../logs/slurm_memr2_eval_<job>.out`。
- 两个 run（bf16、GRPO step 40）没有跑 LLM judge，对应位置是 —。

## 总览（Overall）

| 模型 | F1 | BLEU-1 | LLM judge |
|---|---|---|---|
| Memory-R2 论文设置（fp16） | 33.26 | 28.09 | 70.78 |
| Memory-R2 论文设置（bf16） | 26.63 | 21.77 | — |
| Memory-R2 fp16, len1024 | 33.24 | 28.13 | 72.17 |
| Memory-R2 fp32, len1024 | 33.56 | 28.37 | 71.80 |
| Answer agent = Qwen2.5-7B-Instruct | 45.56 | 39.48 | 78.71 |
| Answer agent = GRPO stage2 step 5 | 50.76 | 44.26 | 77.51 |
| Answer agent = GRPO stage2 step 40 | 50.71 | 43.63 | — |
| Answer agent = GRPO stage2 step 5（重跑并 dump memory ops） | 50.88 | 44.39 | 77.42 |

## Memory-R2 论文设置（fp16）

- Run：`memr2_paper_20261014_020348`（job 2839935）
- Answer agent：`ahmedehabb/Memory-R2-answer-agent`，fp16，max_model_len=32768
- 结果文件：`memr2_paper_20261014_020348_judge_gpt4omini.json`

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 37.95 | 32.47 | 80.31 |
| Multi-hop | 201 | 25.81 | 21.41 | 70.15 |
| Temporal | 237 | 31.52 | 26.07 | 49.79 |
| Open-domain | 58 | 18.61 | 15.01 | 62.07 |
| **Overall** | 1085 | **33.26** | **28.09** | **70.78** |

## Memory-R2 论文设置（bf16）

- Run：`memr2_paper_bf16_20261014_060346`（job 2845432）
- Answer agent：`ahmedehabb/Memory-R2-answer-agent`，bf16，max_model_len=32768
- 结果文件：`memr2_paper_bf16_20261014_060346.json`
- 备注：这个 run 没有跑过 LLM judge。

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 31.57 | 26.21 | — |
| Multi-hop | 201 | 17.97 | 13.32 | — |
| Temporal | 237 | 24.14 | 19.94 | — |
| Open-domain | 58 | 16.65 | 13.51 | — |
| **Overall** | 1085 | **26.63** | **21.77** | **—** |

## Memory-R2 fp16, len1024

- Run：`memr2_paper_fp16_len1024_20261014_132352`（job 2846450）
- Answer agent：`ahmedehabb/Memory-R2-answer-agent`，fp16，max_model_len=13312
- 结果文件：`memr2_paper_fp16_len1024_20261014_132352_judge.json`
- 备注：judge 跑过两次（eval 时一次，之后单独 re-judge 一次），overall 一样（72.17），分类别差 ≤1 分；表里用的是 re-judge 那次（`_judge.json`）。

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 38.42 | 32.88 | 80.48 |
| Multi-hop | 201 | 25.40 | 20.89 | 71.14 |
| Temporal | 237 | 30.77 | 25.74 | 54.01 |
| Open-domain | 58 | 18.02 | 14.66 | 65.52 |
| **Overall** | 1085 | **33.24** | **28.13** | **72.17** |

## Memory-R2 fp32, len1024

- Run：`memr2_paper_fp32_len1024_20261014_135814`（job 2846493）
- Answer agent：`ahmedehabb/Memory-R2-answer-agent`，fp32，max_model_len=13312
- 结果文件：`memr2_paper_fp32_len1024_20261014_135814.json`

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 38.34 | 32.70 | 80.31 |
| Multi-hop | 201 | 26.09 | 21.44 | 69.65 |
| Temporal | 237 | 31.93 | 26.99 | 54.43 |
| Open-domain | 58 | 17.63 | 14.06 | 63.79 |
| **Overall** | 1085 | **33.56** | **28.37** | **71.80** |

## Answer agent = Qwen2.5-7B-Instruct

- Run：`qwen25_7b_inst_aa_20261014_200502`（job 2848879）
- Answer agent：`Qwen/Qwen2.5-7B-Instruct`，bf16，max_model_len=13312
- 结果文件：`qwen25_7b_inst_aa_20261014_200502_judge.json`

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 51.28 | 45.72 | 86.42 |
| Multi-hop | 201 | 35.84 | 29.23 | 79.10 |
| Temporal | 237 | 44.54 | 37.70 | 61.18 |
| Open-domain | 58 | 25.33 | 18.87 | 70.69 |
| **Overall** | 1085 | **45.56** | **39.48** | **78.71** |

## Answer agent = GRPO stage2 step 5

- Run：`aa_stage2_step5_20261016_071035`（job 2855490）
- Answer agent：`answer_agent_grpo/stage2_cont_from_step50_job2854112/global_step_5`，bf16，max_model_len=13312
- 结果文件：`aa_stage2_step5_20261016_071035_judge.json`

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 55.81 | 50.22 | 86.59 |
| Multi-hop | 201 | 37.45 | 29.68 | 74.63 |
| Temporal | 237 | 56.39 | 48.50 | 59.92 |
| Open-domain | 58 | 22.67 | 17.02 | 67.24 |
| **Overall** | 1085 | **50.76** | **44.26** | **77.51** |

## Answer agent = GRPO stage2 step 40

- Run：`aa_stage2_step40_20261016_073036`（job 2855586）
- Answer agent：`answer_agent_grpo/stage2_cont_from_step50_job2854112/global_step_40`，bf16，max_model_len=13312
- 结果文件：`aa_stage2_step40_20261016_073036.json`
- 备注：这个 run 没有跑过 LLM judge。

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 55.85 | 50.51 | — |
| Multi-hop | 201 | 38.31 | 30.78 | — |
| Temporal | 237 | 55.58 | 43.84 | — |
| Open-domain | 58 | 21.60 | 17.42 | — |
| **Overall** | 1085 | **50.71** | **43.63** | **—** |

## Answer agent = GRPO stage2 step 5（重跑并 dump memory ops）

- Run：`memops_aa_stage2_step5_20261018_060927`（job 2866966）
- Answer agent：`answer_agent_grpo/stage2_cont_from_step50_job2854112/global_step_5`，bf16，max_model_len=13312
- 结果文件：`memops_aa_stage2_step5_20261018_060927_judge.json`
- 备注：和 step 5 那个 run 配置相同，只是多开了 `REMA_DUMP_MEMOPS`。主结果文件里的 judge 是 gpt-4o（overall 66.27），这里不用；表里用的是 gpt-4o-mini re-judge 那次（`_judge.json`）。

| Category | n | F1 | BLEU-1 | LLM judge |
|---|---|---|---|---|
| Single-hop | 589 | 56.16 | 50.57 | 86.42 |
| Multi-hop | 201 | 38.00 | 30.20 | 75.12 |
| Temporal | 237 | 55.63 | 47.79 | 59.92 |
| Open-domain | 58 | 22.57 | 16.87 | 65.52 |
| **Overall** | 1085 | **50.88** | **44.39** | **77.42** |
