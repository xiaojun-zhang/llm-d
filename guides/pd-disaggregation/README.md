# P/D Disaggregation

[![Nightly - PD Disaggregation E2E (OpenShift)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-ocp.yaml/badge.svg)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-ocp.yaml) [![Nightly - PD Disaggregation E2E (CKS)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-cks.yaml/badge.svg)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-cks.yaml) [![Nightly - PD Disaggregation E2E (GKE)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-gke.yaml/badge.svg)](https://github.com/llm-d/llm-d/actions/workflows/nightly-e2e-pd-disaggregation-gke.yaml)

## Overview

This guide deploys `openai/gpt-oss-120b` with prefill-decode disaggregation, improving throughput per GPU and quality of service. Since disaggregation is natively built into EPP, we can compose features like prefix- and load-aware routing with disaggregated serving. In this example, we will demonstrate a deployment with:

* 8 TP=1 Prefill Instances
* 2 TP=4 Decode Instances

### P/D Best Practices

P/D disaggregation provides more flexibility in navigating the trade-off between throughput and interactivity([ref](https://arxiv.org/html/2506.05508v1)).
In particular, due to the elimination of prefill interference to the decode phase, P/D disaggregation can achieve lower inter token latency (ITL), thus
improving interactivity. For a given ITL goal, P/D disaggregation can benefit overall throughput by:

* Specializing P and D workers for compute-bound vs latency-bound workloads
* Reducing the number of copies of the model (increasing KV cache RAM) with wide parallelism

However, P/D disaggregation is not a target for all workloads. We suggest exploring P/D disaggregation for workloads with:

* Medium-large models (e.g. gpt-oss-120b+)
* Longer input sequence lengths (e.g 10k ISL | 1k OSL, not 200 ISL | 200 OSL)
* Sparse MoE architectures with opportunities for wide-EP

As a result, as you tune your P/D deployments, we suggest focusing on the following parameters:

* **Heterogeneous Parallelism**: deploy P workers with less parallelism and more replicas and D workers with more parallelism and fewer replicas
* **xPyD Ratios**: tuning the ratio of P workers to D workers to ensure balance for your ISL|OSL ratio

### Supported Hardware Backends

This guide includes configuration for the following accelerators:

| Backend             | Directory                  | Notes                                      |
| ------------------- | -------------------------- | ------------------------------------------ |
| NVIDIA GPU (vLLM)   | `modelserver/gpu/vllm/`    | vLLM, tested nightly                       |
| NVIDIA GPU (SGLang) | `modelserver/gpu/sglang/`  | SGLang, validated each release             |
| Google TPU          | `modelserver/tpu/vllm/`    | GKE TPU, validated each releas             |
| AMD GPU             | `modelserver/amd/vllm/`    | AMD GPU, community contributed             |
| Intel XPU           | `modelserver/xpu/vllm/`    | Intel Data Center GPU Max 1550+            |
| Intel Gaudi (HPU)   | `modelserver/hpu/vllm/`    | Gaudi 1/2/3 with DRA support               |

> [!NOTE]
> Some hardware variants use reduced configurations (fewer replicas, smaller models) to enable CI testing for compatibility and regression checks. These configurations are maintained by their respective hardware vendors and are not guaranteed as production-ready examples. Users deploying on non-default hardware should review and adjust the configurations for their environment.

## Prerequisites

- Have the [proper client tools installed on your local system](../../helpers/client-setup/README.md) to use this guide.
- Checkout llm-d repo:

  ```bash
    export branch="main" # branch, tag, or commit hash
    git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}
  ```
- Set the following environment variables:
  ```bash
    export GAIE_VERSION=v1.4.0
    export GUIDE_NAME="pd-disaggregation"
    export MODEL_NAME="openai/gpt-oss-120b"
  ```
- Install the Gateway API Inference Extension CRDs:

  ```bash
    kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
  ```

## Installation Instructions

### 1. Deploy the Inference Scheduler

#### Standalone Mode

This deploys the inference scheduler with an Envoy sidecar, it doesn't set up a Kubernetes Gateway.

```bash
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
    -f guides/recipes/scheduler/base.values.yaml \
    -f guides/${GUIDE_NAME}/scheduler/${GUIDE_NAME}.values.yaml \
    --version v1.4.0
```

<details>
<summary><h4>Gateway Mode</h4></summary>

To employ a Kubernetes Gateway managed proxy instead of the standalone one, then instead of applying the standalone helm chart above, do the following:

1. *Deploy a Kubernetes Gateway*. Follow [the gateway guides](../prereq/gateways) for step by step deployment for a Gateway named `llm-d-inference-gateway`. You only need to create one Gateway for your cluster, all guides can share one Gateway each with a separate HTTPRoute. 
2. *Deploy the Inference Scheduler and HTTPRoute*. The following deploys the inference scheduler with an HttpRoute that connects it to the Gateway created in the previous step (set `provider.name` to the gateway provider you deployed):

```bash
export PROVIDER_NAME=gke # other na, agentgateway or istio
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool  \
    -f guides/recipes/scheduler/base.values.yaml \
    -f guides/${GUIDE_NAME}/scheduler/${GUIDE_NAME}.values.yaml \
    --set provider.name=${PROVIDER_NAME} \
    --set experimentalHttpRoute.enabled=true \
    --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
    --set experimentalHttpRoute.baseModel=${GUIDE_NAME} \
    --version v1.4.0
```

</details>

### 2. Deploy the Model Server

Apply the Kustomize overlays for your specific backend (defaulting to NVIDIA GPU / vLLM):

> [!NOTE]
> The Kuberentes ecosystem has not yet standardized on how to expose
> NICs to pods. So we provide some pre-configured setups for certain
> Kuberentes providers.

```bash
export INFRA_PROVIDER=base

kubectl apply -k guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}
```

### 3. Enable monitoring (optional)

> [!NOTE]
> GKE provides [automatic application monitoring](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-automatic-application-monitoring) out of the box. The llm-d [Monitoring stack](../../docs/monitoring/README.md) is not required for GKE, but it is available if you prefer to use it.

- Install the [Monitoring stack](../../docs/monitoring/README.md).
- Deploy the monitoring resources for this guide.

```bash
kubectl apply -k guides/recipes/modelserver/components/monitoring
```

## Verification

### 1. Get the IP of the Scheduler

**Standalone Mode**

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -o jsonpath='{.spec.clusterIP}')
```

<details>
<summary> <b>Gateway Mode</b> </summary>

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -o jsonpath='{.status.addresses[0].value}')
```
</details>

### 2. Send Test Requests

**Open a temporary interactive shell inside the cluster:**

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="GUIDE_NAME=$GUIDE_NAME" \
    -- /bin/bash
```

**Send a completion request:**

```bash
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -H 'X-Gateway-Base-Model-Name: '"$GUIDE_NAME"'' \
    -d '{
        "model": '\"${MODEL_NAME}\"',
        "prompt": "How are you today?"
    }' | jq
```

## Benchmarking

### Run Benchmark

We use the [inference-perf](https://github.com/kubernetes-sigs/inference-perf/tree/main) benchmark tool to verify the setup by generating random datasets with 1K input length and 1K output length across different concurrency levels.

1. Deploy the inference PD stack following the Installation steps above. Once the stack is ready, obtain the gateway IP:

```bash
export GATEWAY_IP=$(kubectl get gateway/llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
```

The `GATEWAY_IP` environment variable will be used in the [benchmark template](./benchmark-templates/guide.yaml).

2. Follow the [benchmark guide](../../helpers/benchmark.md) to deploy the benchmark tool and analyze the benchmark results. Notably, select the corresponding benchmark template:

```bash
export BENCH_TEMPLATE_DIR="${LLMD_ROOT_DIR}"/guides/pd-disaggregation/benchmark-templates
export BENCHMARK_TEMPLATE="${BENCH_TEMPLATE_DIR}"/guide.yaml
```

### Results

<img src="latency_vs_concurrency.png" width="900" alt="Latency vs Concurrency">
<img src="throughput_vs_concurrency.png" width="900" alt="Throughput vs Concurrency">
<img src="throughput_vs_latency.png" width="900" alt="Throughput vs Latency">

<details>
<summary><b><i>Click</i></b> for contents of the overall summary file (<code>summary_lifecycle_metrics.json</code>)</summary>

  ```json
  {
    "load_summary": {
      "count": 10500,
      "schedule_delay": {
        "mean": 77.6067300104108,
        "min": -0.0009471391094848514,
        "max": 193.36847741738893,
        "p0.1": -0.0005135770575143397,
        "p1": -9.381271200254551e-05,
        "p5": 0.0006701549165882171,
        "p10": 6.605916145677412,
        "p25": 31.773801590898074,
        "median": 69.96205037651816,
        "p75": 120.88437926475308,
        "p90": 157.18257419392472,
        "p95": 172.30117548274575,
        "p99": 193.24024071463967,
        "p99.9": 193.34426271322974
      }
    },
    "successes": {
      "count": 10500,
      "latency": {
        "request_latency": {
          "mean": 16.949693734689514,
          "min": 7.430527747026645,
          "max": 23.341206387034617,
          "p0.1": 7.546646456788178,
          "p1": 7.670289718103595,
          "p5": 9.628040663100546,
          "p10": 9.954197152797132,
          "p25": 13.491928927513072,
          "median": 17.363681015442125,
          "p75": 20.775550709746312,
          "p90": 21.703451853734443,
          "p95": 22.43754903097288,
          "p99": 23.146584392286606,
          "p99.9": 23.29399677501375
        },
        "normalized_time_per_output_token": {
          "mean": 0.017395157922218466,
          "min": 0.007569078082287961,
          "max": 0.05599903221818888,
          "p0.1": 0.007666992976993649,
          "p1": 0.007779649437568896,
          "p5": 0.009792350577796686,
          "p10": 0.01019379180393505,
          "p25": 0.013799272786547731,
          "median": 0.01784575978899651,
          "p75": 0.02109968625327706,
          "p90": 0.022346508134797133,
          "p95": 0.02311641331519695,
          "p99": 0.024021365913386925,
          "p99.9": 0.0332398016193207
        },
        "time_per_output_token": {
          "mean": 0.015854782856094884,
          "min": 0.007178500500973314,
          "max": 0.020949103697086684,
          "p0.1": 0.007198484788668575,
          "p1": 0.007428308323330711,
          "p5": 0.009125048257928575,
          "p10": 0.009484055226738564,
          "p25": 0.01283546879797359,
          "median": 0.016228663841495287,
          "p75": 0.01970306675226311,
          "p90": 0.020181560415274,
          "p95": 0.020428766423888738,
          "p99": 0.020664510622657836,
          "p99.9": 0.020713284537798724
        },
        "time_to_first_token": {
          "mean": 1.0639281511114733,
          "min": 0.08917623397428542,
          "max": 4.274269078974612,
          "p0.1": 0.10329887501196935,
          "p1": 0.12344494416029192,
          "p5": 0.18211153338779695,
          "p10": 0.22062120221089573,
          "p25": 0.3119133528089151,
          "median": 0.7006767939892597,
          "p75": 1.1240748403070029,
          "p90": 2.8348029804299584,
          "p95": 3.3259600740275332,
          "p99": 4.240478515403811,
          "p99.9": 4.267909067379777
        },
        "inter_token_latency": {
          "mean": 0.015854732319313614,
          "min": 6.483984179794788e-06,
          "max": 1.31577575893607,
          "p0.1": 1.727902120910585e-05,
          "p1": 0.005857429078314453,
          "p5": 0.0076378712663427,
          "p10": 0.009079416235908865,
          "p25": 0.012070255470462143,
          "median": 0.015335309086367488,
          "p75": 0.017898101534228772,
          "p90": 0.019151526875793936,
          "p95": 0.021329846547450872,
          "p99": 0.04715092248981833,
          "p99.9": 0.19980837515836633
        }
      },
      "throughput": {
        "input_tokens_per_sec": 13641.337272379991,
        "output_tokens_per_sec": 12925.396206067344,
        "total_tokens_per_sec": 26566.733478447335,
        "requests_per_sec": 13.241470097289648
      },
      "prompt_len": {
        "mean": 1030.1980952380952,
        "min": 1014.0,
        "max": 1049.0,
        "p0.1": 1014.0,
        "p1": 1016.0,
        "p5": 1020.0,
        "p10": 1022.0,
        "p25": 1025.0,
        "median": 1030.0,
        "p75": 1034.25,
        "p90": 1039.0,
        "p95": 1043.0,
        "p99": 1048.0,
        "p99.9": 1049.0
      },
      "output_len": {
        "mean": 976.13,
        "min": 390.0,
        "max": 1007.0,
        "p0.1": 561.998,
        "p1": 870.0,
        "p5": 947.0,
        "p10": 961.0,
        "p25": 972.0,
        "median": 981.0,
        "p75": 989.0,
        "p90": 994.0,
        "p95": 996.0,
        "p99": 999.0,
        "p99.9": 1001.0
      }
    },
    "failures": {
      "count": 0,
      "request_latency": null,
      "prompt_len": null
    }
  }
  ```

</details>

