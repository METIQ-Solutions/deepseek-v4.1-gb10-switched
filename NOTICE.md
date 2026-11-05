deepseek-v4.1-gb10-switched
Copyright 2026 METIQ Solutions

This repository documents and configures a deployment of third-party software.
It redistributes no third-party source code, no container images, no model
weights and no binaries. This file records the attribution those projects
require and the courtesy their authors are owed.

--------------------------------------------------------------------------------
Upstream runtime and transport — Christopher Owen
--------------------------------------------------------------------------------
christopherowen/spark-ds41f  (Apache License 2.0)
  https://github.com/christopherowen/spark-ds41f
  The optimised DeepSeek V4.1 Flash vLLM runtime: build system, image recipe,
  configuration schema, `bin/spark` lifecycle CLI, benchmarks and documentation.
  This deployment runs this project unmodified at commit
  9461a70546fcfdcac9c7d8fbc58a53230510fbc9 (release spark-ds41f-1030).
  Nothing from its source tree is copied into this repository.

christopherowen/dgx-spark-networking  ("SparkNet", Apache License 2.0)
  https://github.com/christopherowen/dgx-spark-networking
  The RoCE transport layer: topology tooling, node-map schema and validation,
  NCCL transport profiles — including the `switched` / `oneshot-switched`
  profile this deployment selects — and the one-shot collective implementation.
  Pinned here at v0.5.0, commit ed6af327a8953eb71de2ed925a5e605cb5eb6e20.
  Nothing from its source tree is copied into this repository.

christopherowen/dgx-spark-memory-saver  (referenced, not redistributed)
  https://github.com/christopherowen/dgx-spark-memory-saver
  The signed DKMS UVM module the runtime's 64 KiB profile requires.

christopherowen/dgx-spark-fan-control  (referenced, not redistributed)
  https://github.com/christopherowen/dgx-spark-fan-control
  The fan-floor control for NVIDIA P4242 boards. Deliberately not used on the
  ASUS GX10 hardware documented here; see docs/hardware-and-network.md.

Derived configuration: configs/cluster.example.json is a resolved site profile
derived from Owen's Apache-2.0 release recipe releases/spark-ds41f-1030/
cluster.json combined with SparkNet's Apache-2.0 transport profiles. Its
provenance and derivation are documented in configs/README.md and
docs/switched-configuration.md. Apache License 2.0, Copyright 2026 Christopher
Owen, for the upstream portions.

--------------------------------------------------------------------------------
Model
--------------------------------------------------------------------------------
deepseek-ai/DeepSeek-V4.1-Flash-1017  (MIT, per the model card on Hugging Face)
  https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017
  Not redistributed here. Referenced by immutable revision
  1bae0e1088993b9b82de08f59de5be5a34e42170 and obtained by the operator under
  its own terms.

--------------------------------------------------------------------------------
Software built by the upstream recipe (fetched, not redistributed)
--------------------------------------------------------------------------------
vllm-project/vllm                        Apache License 2.0
flashinfer-ai/flashinfer                 Apache License 2.0
NVIDIA/nccl                              BSD 3-Clause
tile-ai/tilelang                         MIT
NVIDIA CUTLASS / CuTe DSL                BSD 3-Clause
NVIDIA CUDA container images             NVIDIA container licence terms
  These are fetched and patched by Owen's `bin/spark build prepare` at pinned
  revisions recorded in his `upstreams.lock.json`. This repository does not
  vendor, mirror or relicense any of them.

--------------------------------------------------------------------------------
Hardware vendor names
--------------------------------------------------------------------------------
ASUS, Ascent and GX10 are trademarks of ASUSTeK Computer Inc. NVIDIA, DGX,
GB10, Grace, Blackwell and ConnectX are trademarks of NVIDIA Corporation. QNAP
and QSW are trademarks of QNAP Systems, Inc. DeepSeek is a trademark of its
owner. Product names are used descriptively; there is no affiliation,
sponsorship or endorsement by any of these companies.

--------------------------------------------------------------------------------
Benchmark and reference material
--------------------------------------------------------------------------------
Performance figures attributed to "the upstream reference" are the published
numbers of spark-ds41f-1030, reproduced here for comparison only. All other
measurements are our own and their conditions are stated in docs/performance.md
and benchmarks/. No third-party benchmark data is redistributed.
