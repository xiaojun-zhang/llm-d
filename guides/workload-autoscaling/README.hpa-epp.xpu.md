# Autoscaling Workloads with HPA and EPP Metrics on Intel XPU

This guide is the Intel XPU validation of the [HPA + EPP Metrics](./README.hpa-epp.md)
well-lit path. It layers a Kubernetes HorizontalPodAutoscaler on top of an
existing [Intel XPU inference-scheduling deployment](../inference-scheduling/README.md#intel-xpu-configuration),
driven by metrics emitted by the Endpoint Picker (EPP).

## Overview

The Endpoint Picker exposes gateway-level signals — queue depth and in-flight
request counts — that reflect the true state of the inference system. These are
scraped by Prometheus, surfaced to Kubernetes via the Prometheus Adapter as
external metrics, and consumed by an HPA that scales the vLLM decode
deployment.

The diagram below shows the end-to-end path:

```
vLLM pods (XPU) ── EPP ──► /metrics ──► Prometheus ──► Prometheus Adapter ──► HPA ──► scales Deployment
```

## Hardware validated

* 8× Intel Arc Pro B60 Graphics (Battlemage / xe driver), single-node kind cluster
* Qwen/Qwen3-0.6B on each pod, 1 XPU per pod (via DRA)

See the [llm-d XPU test environment](../inference-scheduling/README.md#intel-xpu-configuration)
for the shared Intel GPU prerequisites (Intel GPU DRA driver, `accelerator.type: intel`).

## Prerequisites

1. A Kubernetes cluster with the [Intel Resource Drivers for Kubernetes](https://github.com/intel/intel-resource-drivers-for-kubernetes)
   installed — the `gpu.intel.com` DeviceClass must be visible, and at least
   one `ResourceSlice` must be advertising XPU devices. Upstream install:

   ```shell
   helm install --namespace intel-gpu-resource-driver --create-namespace \
     intel-gpu-resource-driver \
     oci://ghcr.io/intel/intel-resource-drivers-for-kubernetes/intel-gpu-resource-driver-chart
   ```

2. The llm-d [monitoring stack](../../docs/monitoring/README.md) (kube-prometheus-stack)
   installed in the `llm-d-monitoring` namespace. The helper script from the repo
   installs both Prometheus and Grafana with the defaults this guide assumes
   (Prometheus service `llmd-kube-prometheus-stack-prometheus`, port `9090`):

   ```shell
   ./docs/monitoring/scripts/install-prometheus-grafana.sh
   ```

3. An `llm-d-hf-token` secret in the target namespace (`llm-d` in this guide),
   holding a HuggingFace token with read access to `Qwen/Qwen3-0.6B`. Without
   it, vLLM pods stall in `CreateContainerConfigError`:

   ```shell
   kubectl create namespace llm-d --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret generic llm-d-hf-token -n llm-d \
     --from-literal=HF_TOKEN="$HF_TOKEN" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. **Enable the `flowControl` EndpointPickerConfig feature gate before deploying
   the inference-scheduling stack.** The HPA+EPP path scales on
   `inference_extension_flow_control_queue_size`, which the EPP only exports
   when the `flowControl` feature gate is on. The stock
   [`guides/inference-scheduling/gaie-inference-scheduling/values.yaml`](../inference-scheduling/gaie-inference-scheduling/values.yaml)
   does not enable it — override it as shown below.

   The inferencepool Helm chart always renders a default plugin config into the
   EPP ConfigMap under the key `default-plugins.yaml`, and that key cannot be
   replaced through Helm values. Instead, use the chart's
   `pluginsCustomConfig` escape hatch to add a second key with the feature gate
   enabled, and point the EPP at it by setting `pluginsConfigFile`.

   Apply the following patch to `guides/inference-scheduling/gaie-inference-scheduling/values.yaml`
   (or maintain a local overlay values file that you pass via
   `helmfile apply --values`):

   ```diff
    inferenceExtension:
      replicas: 1
      flags:
      image:
        name: llm-d-inference-scheduler
        hub: ghcr.io/llm-d
        tag: v0.7.0
        pullPolicy: Always
      extProcPort: 9002
   -  pluginsConfigFile: "default-plugins.yaml"
   +  # Redirect the EPP to a custom plugin config that enables the flowControl
   +  # feature gate required by the HPA+EPP autoscaling guide.
   +  pluginsConfigFile: "custom-plugins.yaml"
   +  pluginsCustomConfig:
   +    custom-plugins.yaml: |
   +      apiVersion: inference.networking.x-k8s.io/v1alpha1
   +      kind: EndpointPickerConfig
   +      featureGates:
   +        - flowControl
   +      plugins:
   +      - type: queue-scorer
   +      - type: kv-cache-utilization-scorer
   +      - type: prefix-cache-scorer
   +      schedulingProfiles:
   +      - name: default
   +        plugins:
   +        - pluginRef: queue-scorer
   +          weight: 2
   +        - pluginRef: kv-cache-utilization-scorer
   +          weight: 2
   +        - pluginRef: prefix-cache-scorer
   +          weight: 3
   ```

   The `plugins` and `schedulingProfiles` blocks are copied verbatim from the
   chart's default config so the only effective change is the added
   `featureGates: [flowControl]` line.

5. Deploy the [Intel XPU inference-scheduling stack](../inference-scheduling/README.md)
   via `helmfile apply -e xpu -n llm-d`. This guide assumes the default release
   names (`infra-inference-scheduling`, `gaie-inference-scheduling`,
   `ms-inference-scheduling`) and namespace (`llm-d`).

   After the EPP pod is Running, confirm it loaded the custom config:

   ```shell
   kubectl logs -n llm-d deploy/gaie-inference-scheduling-epp | grep -i "flow control"
   ```

   Expected: `Initializing experimental Flow Control layer`.

6. Apply the `HTTPRoute` that attaches the `InferencePool` to the gateway.
   The `llm-d-modelservice` v0.4.9 chart does **not** auto-create one despite
   some upstream docs implying otherwise, so without this step the gateway
   returns 404 and Step 1's `curl` will fail:

   ```shell
   kubectl apply -f ../inference-scheduling/httproute.yaml -n llm-d
   ```

   Wait for all 8 decode pods to reach `1/1 Ready`:

   ```shell
   kubectl get pods -n llm-d -l llm-d.ai/inference-serving=true -w
   ```

   First-run `torch.compile` warmup on BMG (Battlemage / xe) can take several
   minutes per pod; don't kill pods mid-warmup.

## Step 1 — Verify the EPP is exposing flow-control metrics

After deploying the inference-scheduling stack, send at least one request through
the gateway (the EPP does not export per-queue metrics until it sees traffic):

```shell
kubectl port-forward -n llm-d svc/infra-inference-scheduling-inference-gateway-istio 8080:80 &
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"max_tokens":20,"chat_template_kwargs":{"enable_thinking":false}}'
```

Confirm the metrics show up in Prometheus:

```shell
kubectl port-forward -n llm-d-monitoring svc/llmd-kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=inference_extension_flow_control_queue_size' | python3 -m json.tool
curl -s 'http://localhost:9090/api/v1/query?query=inference_objective_running_requests' | python3 -m json.tool
```

Both queries should return a vector with at least one sample (value may be `0`
when idle — that is expected).

## Step 2 — Install the Prometheus Adapter

The Prometheus Adapter turns Prometheus series into Kubernetes external
metrics. Create a values file `prometheus-adapter-values.yaml`:

```yaml
prometheus:
  url: http://llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc
  port: 9090

rules:
  external:
    - seriesQuery: 'inference_extension_flow_control_queue_size'
      resources:
        overrides:
          namespace:
            resource: "namespace"
      name:
        as: "epp_queue_size"
      metricsQuery: 'sum(inference_extension_flow_control_queue_size{inference_pool="gaie-inference-scheduling"})'
    - seriesQuery: 'inference_objective_running_requests'
      resources:
        overrides:
          namespace:
            resource: "namespace"
      name:
        as: "epp_running_requests"
      metricsQuery: 'sum(inference_objective_running_requests{job="gaie-inference-scheduling-epp"})'
```

Install the adapter into `llm-d-monitoring`:

```shell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace llm-d-monitoring \
  --version 4.14.1 \
  --values prometheus-adapter-values.yaml
```

The values above declare two external metrics:

| External metric | Series | Description |
|---|---|---|
| `epp_queue_size` | `inference_extension_flow_control_queue_size{inference_pool="gaie-inference-scheduling"}` | Number of requests buffered in the EPP flow-control queue |
| `epp_running_requests` | `inference_objective_running_requests{job="gaie-inference-scheduling-epp"}` | Number of concurrent requests in flight across the pool |

> **Note:** The `job` label is used on `inference_objective_running_requests`
> rather than the `top_level_controller_name` label shown in the generic
> [HPA + EPP doc](./README.hpa-epp.md) — that label is not emitted by the
> inferencepool v1.4.0 chart. `job` is populated by Prometheus from the
> ServiceMonitor, and resolves to `gaie-inference-scheduling-epp` with the
> default release names.

## Step 3 — Verify external metrics are visible to Kubernetes

```shell
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" | python3 -m json.tool
```

Expected output includes both `epp_queue_size` and `epp_running_requests`.

Query the current values:

```shell
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/llm-d/epp_queue_size"
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/llm-d/epp_running_requests"
```

## Step 4 — Apply the HPA

Create `hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ms-inference-scheduling-llm-d-modelservice-decode
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ms-inference-scheduling-llm-d-modelservice-decode
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: External
      external:
        metric:
          name: epp_queue_size
        target:
          type: Value
          value: "5"
    - type: External
      external:
        metric:
          name: epp_running_requests
        target:
          type: AverageValue
          averageValue: "4"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
```

Apply it:

```shell
kubectl apply -f hpa.yaml -n llm-d
```

The HPA targets the `ms-inference-scheduling-llm-d-modelservice-decode`
Deployment and scales between 1 and 4 replicas. Thresholds are tuned for this
XPU test profile (Qwen/Qwen3-0.6B, 1 XPU per pod):

* `epp_queue_size`: `Value`, target `5`
* `epp_running_requests`: `AverageValue`, target `4` per pod

Scale-up is immediate (no stabilization window); scale-down is delayed by 300
seconds to prevent flapping.

Confirm the HPA is reading both metrics:

```shell
kubectl get hpa -n llm-d
```

Expected (idle cluster):

```
NAME                                                REFERENCE                                                      TARGETS          MINPODS   MAXPODS   REPLICAS
ms-inference-scheduling-llm-d-modelservice-decode   Deployment/ms-inference-scheduling-llm-d-modelservice-decode   0/5, 0/4 (avg)   1         4         1
```

## Step 5 — Drive load and observe scaling

Any load generator works. The minimal reproducer used to validate this guide:

```shell
#!/bin/bash
# loadgen.sh — 12 concurrent workers for 5 minutes
CONCURRENCY=12 DURATION=300
kubectl port-forward -n llm-d svc/infra-inference-scheduling-inference-gateway-istio 8080:80 &
sleep 2
end=$(( $(date +%s) + DURATION ))
for i in $(seq 1 $CONCURRENCY); do
  (while [ $(date +%s) -lt $end ]; do
    curl -s -o /dev/null -X POST http://localhost:8080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Write a short story about a robot learning to paint. Keep it about 200 words."}],"max_tokens":300,"chat_template_kwargs":{"enable_thinking":false}}'
  done) &
done
wait
```

Watch the HPA scale up:

```shell
watch -n 5 kubectl get hpa,pods -n llm-d
```

Observed behavior on the 8× Arc Pro B60 test host with Qwen/Qwen3-0.6B:

| Phase | Time from load start | Replicas | Notes |
|---|---|---|---|
| Load ramp | t=0 | 1 | `running_requests` climbs past 4 as vLLM admits concurrent batches |
| First scale-up | ~20 s | 2 | HPA reacts immediately (no stabilization window) |
| 2nd pod ready | ~3 min | 2 | DRA GPU allocation + image pull + torch.compile warmup on BMG |
| Second scale-up | ~5 min | 3 | Once pod 2 joined the pool, concurrency redistributed and load still exceeded target |
| Steady state | ~6 min | 3 | `running_requests ≈ 4/pod` — HPA target exactly satisfied |
| Load stops | t≈5 min load | 3 | Both metrics drop to 0 |
| Scale-down | ~5 min after load ends | 1 | 300 s stabilization window, then aggressive 100%-per-15 s scale-down policy takes it straight to `minReplicas` |

The scale-down jump from 3 to 1 (rather than stepping 3→2→1) is a consequence
of the `scaleDown.policies[0].value: 100` setting, which allows removing up to
100% of replicas per 15 s step once the stabilization window passes. Tune this
down (for example `value: 50`) if you want more conservative scale-in.

## Step 6 — Cleanup

Remove the HPA and the Prometheus Adapter:

```shell
kubectl delete hpa ms-inference-scheduling-llm-d-modelservice-decode -n llm-d
helm uninstall prometheus-adapter -n llm-d-monitoring
```

To also tear down the inference-scheduling stack, follow the [inference-scheduling
cleanup section](../inference-scheduling/README.md#cleanup).

## Versions validated

| Component | Version |
|---|---|
| Kubernetes | v1.35.0 (kind) |
| llm-d-infra Helm chart | v1.4.0 |
| llm-d-modelservice Helm chart | v0.4.9 |
| inferencepool Helm chart | v1.4.0 |
| EPP image | `ghcr.io/llm-d/llm-d-inference-scheduler:v0.7.0` |
| vLLM XPU image | `ghcr.io/llm-d/llm-d-xpu:v0.6.0` |
| Prometheus Adapter | chart 4.14.1 (image v0.12.0) |
| Model | Qwen/Qwen3-0.6B |
| Hardware | 8× Intel Arc Pro B60 (BMG/xe), Ubuntu 24.04 |
