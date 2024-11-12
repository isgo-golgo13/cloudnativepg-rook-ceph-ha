## Kubernetes Helm Chart for CNPG Cluster Pod (Primary) Shutdown

The following sources provide a Job, CronJob and an associated Config as an argument list for running a `Chaos Mesh` Helm Chart pre-deployed `PodChaos` resource in a Kubernetes Job to an actively runnung CNPG Cluster to shutdown the CNPG Cluster `primary` and force trigger the CNPG Cluster `standby` into leader-election and serve as the new CNPG Cluster `primary` without data-loss. This service can run either as a Kubernetes `Job` or `CronJob`.


## Prerequisites

- Kubernetes 1.30+
- Helm 3.0+
- Chaos Mesh Helm Chart Installation

