Notes
=====

```bash
eksdemo create cluster testing-013-r1-distill-qwen-32b \
  --os AmazonLinux2023 \
  --instance g4dn.12xlarge \
  --max 2 --nodes 2 \
  --volume-size 2048 --volume-type io2 \
  --no-taints
```

```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
```

```bash
helm install lws $HOME/go/src/sigs.k8s.io/lws/charts/lws --create-namespace --namespace lws-system
```

```bash
kubectl apply -f deepseek-lws.yaml
```

```bash
kubectl port-forward svc/vllm-leader 8000:8080
```

```bash
eksdemo delete cluster testing-013-r1-distill-qwen-32b
```

Appendix
========

If you want to create a nodegroup with p4d.24xlarge instances AFTER creating an eks cluster, you can use the following command:

```bash
cat <<EOF | eksctl create nodegroup -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $(eksctl get clusters -o json | jq -r '.[0].Name')  # Dynamically pick the first cluster
  region: ${AWS_REGION}  # Use the AWS_REGION environment variable

managedNodeGroups:
  - name: p4d-nodegroup
    amiFamily: AmazonLinux2023
    instanceType: p4d.24xlarge
    minSize: 1
    maxSize: 3
    desiredCapacity: 3
    volumeSize: 2048
    volumeType: io2
    volumeIOPS: 16000
    iam:
      attachPolicyARNs:
      - "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      - "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      - "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      - "arn:aws:iam::aws:policy/AmazonS3FullAccess"
    privateNetworking: true
    spot: false
EOF
```
