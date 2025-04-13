Notes
=====

- Create a new EKS cluster with the following command:
```bash
eksdemo create cluster deepseek-v3-cluster-001 \
  --os AmazonLinux2023 \
  --instance g6e.48xlarge \
  --max 4 --nodes 4 \
  --volume-size 2048 \
  --enable-efa \
  --addons eks-pod-identity-agent \
  --no-taints \
  --timeout 120m
```
If you want to inspect the eksctl config generated add `--dry-run` to the command above.

- To grab the kubeconfig for the new cluster, use the following command:
```bash
eksctl utils write-kubeconfig --cluster=$(eksctl get cluster -o json | jq -r '.[0].Name')
```
- To delete the cluster, use the following command:
```bash
eksdemo delete cluster $(eksctl get cluster -o json | jq -r '.[0].Name')
```
- Install the [LeaderWorkerSet API (LWS)](https://github.com/kubernetes-sigs/lws) with the following command:
```bash
helm install lws $HOME/go/src/sigs.k8s.io/lws/charts/lws --create-namespace --namespace lws-system
```

- Install the deepseek deployer that runs the DeepSeek-R1 distilled model with the following command:
```bash
kubectl apply -f deepseek-lws.yaml
```

- To access the DeepSeek-V3 model using your localhost, use the following command:
```bash
kubectl port-forward svc/vllm-leader 8000:8000 8265:8265
```
Links
=====
- https://huggingface.co/deepseek-ai/DeepSeek-R1
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E/hosting-deepseek-r1-on-amazon-eks
- https://apxml.com/posts/gpu-requirements-deepseek-r1
- https://unsloth.ai/blog/deepseekr1-dynamic
- https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/machine-learning/multi-node-vllm/#dockerfile
- https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/patterns/multi-node-vllm/Dockerfile
- https://github.com/aws-samples/sagemaker-genai-hosting-examples/blob/main/Deepseek/DeepSeek-R1-LMI-FP8.ipynb
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E/hosting-deepseek-r1-on-amazon-eks

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
