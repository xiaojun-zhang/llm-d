# Gateway Guides

This directory contains guides for deploying a k8s Gateway managed proxy for the Inference Scheduler via the following Gateway providers:

* [GKE Gateway](./gke.md) - GKE's implementation of the Gateway API is through the GKE Gateway controller which provisions Google Cloud Load Balancers for Pods in GKE clusters. The [GKE Gateway controller](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/gateway-api) supports weighted traffic splitting, mirroring, advanced routing, multi-cluster load balancing and more. 
* [Istio](./istio.md) - [Istio](https://istio.io/) is an open source service mesh and gateway implementation. It provides a fully compliant implementation of the Kubernetes Gateway API for cluster ingress traffic control. 
* [AgentGateway](./agentgateway.md) - [Agentgateway](https://agentgateway.dev/) is a high-performance, Rust-based AI gateway for LLM, MCP, and A2A workloads that can also serve as a Gateway API and Inference Gateway implementation.
