# Helm chart repository

This branch is generated. [chart-releaser](https://github.com/helm/chart-releaser) writes `index.yaml`
and the packaged `.tgz` files here on every release from `main`; nothing else belongs on it, and hand
edits are lost on the next run.

```bash
helm repo add group-sync-operator https://ephico2real2.github.io/group-sync-operator-helm-chart
helm repo update
helm search repo group-sync-operator-helm
```

Chart source and documentation live on `main`, under `charts/group-sync-operator-helm`.
