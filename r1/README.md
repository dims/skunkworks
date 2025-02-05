Notes
=====

```bash
eksdemo create cluster testing-011-deep-seek-llama-r1 --os AmazonLinux2023 --instance m6a.4xlarge --max 3 --nodes 3 --volume-size 2048 --volume-type io2
```

```bash
cat <<EOF | eksctl create nodegroup -f - --timeout 180m
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


// p4d.24xlarge

```bash
helm install lws $HOME/go/src/sigs.k8s.io/lws/charts/lws --create-namespace --namespace lws-system
```

```bash
kubectl apply -f deepseek-lws.yaml
```

```bash
eksdemo delete cluster testing-011-deep-seek-llama-r1
```
