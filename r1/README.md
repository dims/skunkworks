Notes
=====

```bash
eksdemo create cluster testing-deep-seek-llama-r1 -v "1.32" --instance p4d.24xlarge --max 3 --nodes 3 --no-taints
```

```bash
helm install lws $HOME/go/src/sigs.k8s.io/lws/charts/lws --create-namespace --namespace lws-system
```

```bash
kubectl apply -f deepseek-lws.yaml
```

```bash
eksdemo delete cluster testing-deep-seek-llama-r1
```
