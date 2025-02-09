Notes
=====

```bash
eksdemo create cluster testing-016-r1 \
  --os AmazonLinux2023 \
  --instance g5.12xlarge \
  --max 4 --nodes 4 \
  --volume-size 2048 --volume-type io2 --volume-iops 10000 \
  --enable-efa \
  --addons eks-pod-identity-agent \
  --no-taints \
  --timeout 120m
```

```bash
eksdemo delete cluster $(eksctl get cluster -o json | jq -r '.[0].Name')
```

```bash
helm install lws $HOME/go/src/sigs.k8s.io/lws/charts/lws --create-namespace --namespace lws-system
```

```bash
kubectl apply -f sa.yaml
aws eks create-pod-identity-association --cluster-name $(eksctl get cluster -o json | jq -r '.[0].Name') \
  --namespace default \
  --service-account my-service-account \
  --role-arn arn:aws:iam::086752300739:role/S3ReadRole
```

```bash
kubectl apply -f deepseek-lws.yaml
```

```bash
kubectl port-forward svc/vllm-leader 8000:8000
```

Links
=====
- https://huggingface.co/deepseek-ai/DeepSeek-R1
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E/hosting-deepseek-r1-on-amazon-eks
- https://apxml.com/posts/gpu-requirements-deepseek-r1
- https://unsloth.ai/blog/deepseekr1-dynamic
- https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/machine-learning/multi-node-vllm/#dockerfile
- https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/patterns/multi-node-vllm/Dockerfile

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

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-efa-k8s-device-plugin --namespace kube-system eks/aws-efa-k8s-device-plugin
```

```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
```
