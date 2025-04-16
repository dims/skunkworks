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

- Wait for the pods to be in a running state. You can check the status of the pods with the following command:
```bash
kubectl get pods
NAME       READY   STATUS    RESTARTS   AGE
vllm-0     1/1     Running   0          7m34s
vllm-0-1   1/1     Running   0          7m34s
vllm-0-2   1/1     Running   0          7m34s
vllm-0-3   1/1     Running   0          7m34s
```

To watch (follow) the logs in vllm-0, use the following command:
```bash
kubectl logs vllm-0 -f
```

wait till you see the following message:
```bash
45986 INFO 04-14 21:43:57 [api_server.py:1081] Starting vLLM API server on http://0.0.0.0:8000
45987 INFO 04-14 21:43:57 [launcher.py:26] Available routes are:
45988 INFO 04-14 21:43:57 [launcher.py:34] Route: /openapi.json, Methods: HEAD, GET
45989 INFO 04-14 21:43:57 [launcher.py:34] Route: /docs, Methods: HEAD, GET
45990 INFO 04-14 21:43:57 [launcher.py:34] Route: /docs/oauth2-redirect, Methods: HEAD, GET
45991 INFO 04-14 21:43:57 [launcher.py:34] Route: /redoc, Methods: HEAD, GET
45992 INFO 04-14 21:43:57 [launcher.py:34] Route: /health, Methods: GET
45993 INFO 04-14 21:43:57 [launcher.py:34] Route: /load, Methods: GET
45994 INFO 04-14 21:43:57 [launcher.py:34] Route: /ping, Methods: POST, GET
45995 INFO 04-14 21:43:57 [launcher.py:34] Route: /tokenize, Methods: POST
45996 INFO 04-14 21:43:57 [launcher.py:34] Route: /detokenize, Methods: POST
45997 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/models, Methods: GET
45998 INFO 04-14 21:43:57 [launcher.py:34] Route: /version, Methods: GET
45999 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/chat/completions, Methods: POST
46000 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/completions, Methods: POST
46001 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/embeddings, Methods: POST
46002 INFO 04-14 21:43:57 [launcher.py:34] Route: /pooling, Methods: POST
46003 INFO 04-14 21:43:57 [launcher.py:34] Route: /score, Methods: POST
46004 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/score, Methods: POST
46005 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/audio/transcriptions, Methods: POST
46006 INFO 04-14 21:43:57 [launcher.py:34] Route: /rerank, Methods: POST
46007 INFO 04-14 21:43:57 [launcher.py:34] Route: /v1/rerank, Methods: POST
46008 INFO 04-14 21:43:57 [launcher.py:34] Route: /v2/rerank, Methods: POST
46009 INFO 04-14 21:43:57 [launcher.py:34] Route: /invocations, Methods: POST
```

- To access the DeepSeek-V3 model using your localhost, use the following command:
```bash
kubectl port-forward svc/vllm-leader 8000:8000 8265:8265
```

- To check if the model is registered using the openapi spec, use the following command:
```bash
curl -X GET "http://127.0.0.1:8000/v1/models" | jq
```

- To test the deployment use the following command:
```bash
time curl -X POST "http://127.0.0.1:8000/v1/chat/completions" \
-H "Content-Type: application/json" \
-d '{
    "model": "deepseek-ai/DeepSeek-V3",
    "messages": [
        {
            "role": "user",
            "content": "What is Kubernetes?"
        }
    ]
}'
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
