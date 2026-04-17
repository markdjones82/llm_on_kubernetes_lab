# Hosting AI Applications on Kubernetes — Lab Guide
adapted for AWS EC2 (Ubuntu 24.04, g5.xlarge A10G GPU, kubeadm 1.35).

---

## Infrastructure

| Role | Instance Type | IP |
|---|---|---|
| Control Plane | t3.medium | (assigned by Terraform) |
| GPU Worker | g5.xlarge (A10G, 24GB) | (assigned by Terraform) |

Connect via SSM:
```bash
aws ssm start-session --region <your-region> --target <instance-id>
 
---

## Day 1

### 1. Provision Infrastructure

The Terraform in `terraform/` provisions both nodes with userdata that installs:
- `containerd.io` (Docker repo) with `SystemdCgroup = true`, CRI plugin enabled, pause image `3.10`
- kernel modules: `overlay`, `br_netfilter`, `nf_conntrack`
- `kubeadm`, `kubelet`, `kubectl` (held at specified version)
- `helm`

```bash

cd terraform
terraform apply -var-file=vars/myenv.tfvars -auto-approve
```

---

### 2. Initialise the Control Plane

SSH/SSM into the control plane node:

```bash
# Fix containerd CRI plugin if disabled (Ubuntu package quirk)
sudo sed -i '/^\s*disabled_plugins\s*=.*"cri"/d' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info

# Initialise the cluster
sudo kubeadm init

# Set up kubectl for ubuntu user
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify
kubectl get nodes
```

---

### 3. Install Calico Network Plugin

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

# Wait for calico pods to be running
kubectl get pods -n kube-system -w
```

---

### 4. Join the GPU Worker Node

On the **control plane**, generate the join command:

```bash
sudo kubeadm token create --print-join-command
```

On the **GPU worker node**, run the printed `kubeadm join` command with `sudo`. Then fix containerd the same way as the control plane:

```bash
sudo sed -i '/^\s*disabled_plugins\s*=.*"cri"/d' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Back on the control plane, verify both nodes are Ready:

```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME                STATUS   ROLES           AGE   VERSION
k8s-control-plane   Ready    control-plane   ...   v1.35.x
k8s-gpu-worker      Ready    <none>          ...   v1.35.x
```

---

### 5. Install the NVIDIA GPU Operator

The GPU operator manages drivers, container toolkit, device plugin, and feature discovery — no manual driver installation needed.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install gpu-operator nvidia/gpu-operator \
  --namespace nvidia-gpu-operator \
  --create-namespace
```

> **Note:** Do NOT use `--set driver.enabled=false` unless you have pre-installed drivers manually. Let the operator manage drivers.

Watch pods come up (driver install takes ~5-10 min):

```bash
kubectl get pods -n nvidia-gpu-operator -w
```

Expected final state — all pods `Running` or `Completed`:
```
nvidia-driver-daemonset             1/1  Running
nvidia-container-toolkit-daemonset  1/1  Running
nvidia-device-plugin-daemonset      1/1  Running
nvidia-dcgm                         1/1  Running
nvidia-dcgm-exporter                1/1  Running
gpu-feature-discovery               1/1  Running
nvidia-operator-validator           1/1  Running
nvidia-cuda-validator               0/1  Completed
```

---

### 6. Verify GPU Access

Check GPU labels on the worker node:

```bash
kubectl get node k8s-gpu-worker --show-labels | tr ',' '\n' | grep nvidia
```

Key labels to look for:
- `nvidia.com/gpu.present=true`
- `nvidia.com/gpu.product=NVIDIA-A10G`
- `nvidia.com/gpu.memory=24576`

Check allocatable GPU resources:

```bash
kubectl describe node k8s-gpu-worker | grep -A6 "Allocatable"
# Should show: nvidia.com/gpu: 1
```

Run a GPU test pod:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-A10G
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: nvidia-smi
      image: nvidia/cuda:12.4.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

kubectl logs gpu-test
kubectl delete pod gpu-test
```

A successful `nvidia-smi` output confirms the GPU operator is fully functional.

---

### 7. Configure GPU Time-Slicing (Optional)

Time-slicing allows multiple containers to share one GPU — useful for inference workloads.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: nvidia-gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        renameByDefault: true
        resources:
        - name: nvidia.com/gpu
          replicas: 4
EOF
```

Patch the ClusterPolicy to use the config:

```bash
kubectl edit clusterpolicy cluster-policy
# Add under spec.devicePlugin:
#   config:
#     name: nvidia-device-plugin-config
#     default: any
```

Verify time-sliced resources are available:

```bash
kubectl describe node k8s-gpu-worker | grep nvidia.com/gpu
# Should now show: nvidia.com/gpu.shared: 4
```

---

## Day 2

### 8. Prepare Storage for Model Files

HostPath (simple, single-node):

```bash
# On the GPU worker node
sudo mkdir -p /opt/models
sudo chmod 777 /opt/models
```

Apply PV/PVC:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: models-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  hostPath:
    path: /opt/models
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: models-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
EOF

kubectl get pv,pvc
```

---

### 9. Download and Run an LLM (llama.cpp)

Download a GGUF model (e.g. Llama-3.2-3B):

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: download-llm
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        nvidia.com/gpu.present: "true"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: models-pvc
      containers:
        - name: downloader
          image: curlimages/curl:8.7.1
          command:
            - sh
            - -c
            - |
              curl -L -o /models/llama-3.2-3b.gguf \
                "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
          volumeMounts:
            - name: models
              mountPath: /models
EOF

kubectl wait --for=condition=complete job/download-llm --timeout=900s
```

Deploy the inference server:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llama-server
  template:
    metadata:
      labels:
        app: llama-server
    spec:
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-A10G
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: models-pvc
      containers:
        - name: llama-server
          image: ghcr.io/ggerganov/llama.cpp:server-cuda
          args:
            - --model
            - /models/llama-3.2-3b.gguf
            - --host
            - "0.0.0.0"
            - --port
            - "8080"
            - --n-gpu-layers
            - "999"
          ports:
            - containerPort: 8080
          resources:
            limits:
              nvidia.com/gpu: 1
          volumeMounts:
            - name: models
              mountPath: /models
---
apiVersion: v1
kind: Service
metadata:
  name: llama-service
spec:
  selector:
    app: llama-server
  ports:
    - port: 8080
      targetPort: 8080
EOF

kubectl rollout status deployment/llama-server
```

Test with a single completion:

```bash
kubectl run llama-cli --rm -it --restart=Never \
  --image=curlimages/curl:8.7.1 -- \
  sh -c 'curl -s -X POST http://llama-service:8080/completion \
    -H "Content-Type: application/json" \
    -d "{\"prompt\":\"Hello from Kubernetes!\",\"n_predict\":64}"'
```

Test with the OpenAI-compatible chat endpoint (multi-turn conversation):

```bash
kubectl run llama-chat --rm -it --restart=Never \
  --image=curlimages/curl:8.7.1 -- \
  sh -c 'curl -s -X POST http://llama-service:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"llama\",
      \"messages\": [
        {\"role\": \"system\", \"content\": \"You are a helpful assistant.\"},
        {\"role\": \"user\", \"content\": \"What is Kubernetes and why is it useful for AI workloads?\"}
      ],
      \"max_tokens\": 256,
      \"temperature\": 0.7
    }" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[\"choices\"][0][\"message\"][\"content\"])"'
```

For an interactive multi-turn session from inside the cluster:

```bash
kubectl run llama-interactive --rm -it --restart=Never \
  --image=python:3.12-slim -- \
  bash -c '
pip install openai -q
python3 - <<EOF
from openai import OpenAI

client = OpenAI(base_url="http://llama-service:8080/v1", api_key="none")
history = [{"role": "system", "content": "You are a helpful assistant."}]

print("Chat with your LLM (type exit to quit)\n")
while True:
    user_input = input("You: ")
    if user_input.lower() == "exit":
        break
    history.append({"role": "user", "content": user_input})
    response = client.chat.completions.create(model="llama", messages=history, max_tokens=256)
    reply = response.choices[0].message.content
    history.append({"role": "assistant", "content": reply})
    print(f"Assistant: {reply}\n")
EOF
'
```

> **How conversation memory works:** The LLM server is completely stateless — it
> has no memory between requests. Every call to `/v1/chat/completions` is
> independent. The `history` list in the script above *is* the memory: each turn
> appends both the user message and the assistant reply, then the full list is
> sent with every new request. The model "remembers" because it re-reads the
> entire conversation each time. This also means if you kill the pod and restart
> it, no history is lost from the model's perspective — it never had any.

---

### 10. Add HPA with Metrics Server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}"

kubectl top nodes
kubectl top pods
```

Apply HPA:

```bash
kubectl apply -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: llama-server-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: llama-server
  minReplicas: 1
  maxReplicas: 4   # Should not exceed available time-slices
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
EOF

kubectl get hpa llama-server-hpa -w
```

---

### 11. NFS Storage Provisioner (Multi-Node)

On the **control plane**:

```bash
sudo apt install nfs-server -y
sudo mkdir /nfsexport
sudo sh -c 'echo "/nfsexport *(rw,no_root_squash)" > /etc/exports'
sudo systemctl restart nfs-server
```

On **worker nodes**:

```bash
sudo apt install nfs-client -y
showmount -e <control-plane-ip>
```

Install the provisioner:

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

helm install nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=<control-plane-ip> \
  --set nfs.path=/nfsexport

kubectl get pods  # verify nfs provisioner pod is running
```

Set as default StorageClass:

```bash
kubectl patch storageclass nfs-client \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```

---

### 12. Expose the LLM via Gateway API

Install NGINX Gateway Fabric:

```bash
# Install CRDs
kubectl kustomize \
  "https://github.com/nginxinc/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.2.1" \
  | kubectl apply -f -

# Install controller
helm install ngf \
  oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric \
  --create-namespace -n nginx-gateway \
  --set service.type=NodePort

kubectl get pods,svc -n nginx-gateway
kubectl get gatewayclass  # note the name (nginx)
```

Configure routing:

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llama-gateway
  namespace: default
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llama-route
  namespace: default
spec:
  parentRefs:
    - name: llama-gateway
  hostnames:
    - "llama.example.com"
  rules:
    - backendRefs:
        - name: llama-service
          port: 8080
EOF
```

Test:

```bash
NODE_PORT=$(kubectl get svc -n nginx-gateway ngf-nginx-gateway-fabric \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
curl -H "Host: llama.example.com" http://<worker-node-ip>:$NODE_PORT/health
```

---

## Resource Reference

### Pod spec best practices for GPU workloads

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: app
      resources:
        requests:
          cpu: "4"
          memory: "8Gi"
          nvidia.com/gpu: 1
        limits:
          cpu: "4"
          memory: "8Gi"
          nvidia.com/gpu: 1
```

### PodDisruptionBudget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: llama-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: llama-server
```

### PriorityClass for GPU workloads

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: gpu-llm-high
value: 100000
globalDefault: false
description: "High priority for LLM GPU workloads"
```

### Spread workload across GPU nodes

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: llama-server
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rpc error: unknown service runtime.v1.RuntimeService` | containerd CRI plugin disabled | `sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml && systemctl restart containerd` |
| GPU operator pods stuck in `Init:0/1` | Driver not installed / `driver.enabled=false` | Reinstall operator without `--set driver.enabled=false` |
| Pod pending: `didn't match node affinity/selector` | Wrong label value in nodeSelector | Check exact label: `kubectl get node <node> --show-labels \| grep nvidia` |
| Pod pending: `untolerated taint` | GPU node tainted by operator | Add `tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]` |
| `invalid hash … expected 32 byte SHA-256` | kubeadm join hash truncated in copy-paste | Regenerate: `sudo kubeadm token create --print-join-command` |
| `nvidia-driver-daemonset` not present | Operator installed with `driver.enabled=false` | `kubectl patch clusterpolicy/cluster-policy --type=merge -p '{"spec":{"driver":{"enabled":true}}}'` |

---

## Swapping the LLM Model

This section walks through replacing the default Mistral 7B with
**Qwen3.6-35B-A3B** (IQ4_XS, ~18.8 GB) — a brand-new April 2026 MoE model
(35B total params, only 3B active per token) that fits comfortably in the A10G's
24 GB VRAM.

### Why Qwen3.6-35B-A3B IQ4_XS?

| Property | Value |
|---|---|
| Architecture | `qwen35moe` — supported by llama.cpp ≥ b8809 |
| Active params | ~3B (256 experts, 8 routed + 1 shared per token) |
| VRAM (IQ4_XS GGUF) | ~18.8 GB |
| Remaining VRAM for KV cache | ~5 GB on A10G 24 GB |
| Context window | 262,144 tokens natively |
| Reasoning | Thinks before answering by default |
| Quant source | [bartowski/Qwen_Qwen3.6-35B-A3B-GGUF](https://huggingface.co/bartowski/Qwen_Qwen3.6-35B-A3B-GGUF) |

---

### Step 1 — Check what is already downloaded

```bash
# Look at what GGUF files are on the NFS volume
find /nfsexport -name "*.gguf" -ls

# Or from inside the cluster, run a quick pod against the PVC
kubectl run check-models --rm -it --restart=Never \
  --image=busybox \
  --overrides='{"spec":{"volumes":[{"name":"m","persistentVolumeClaim":{"claimName":"models-pvc"}}],"containers":[{"name":"c","image":"busybox","command":["ls","-lh","/models"],"volumeMounts":[{"name":"m","mountPath":"/models"}]}]}}' \
  -- ls -lh /models
```

---

### Step 2 — Delete the old download job

Kubernetes Jobs are immutable once created — you must delete and recreate to
change the model URL.

```bash
kubectl delete job download-llm --ignore-not-found
```

Confirm it is gone:

```bash
kubectl get jobs
```

---

### Step 3 — Create a new download job for Qwen3.6

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: download-llm
spec:
  template:
    spec:
      restartPolicy: OnFailure
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: models-pvc
      containers:
      - name: downloader
        image: curlimages/curl:8.7.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          MODEL_PATH=/models/Qwen_Qwen3.6-35B-A3B-IQ4_XS.gguf
          if [ -f "$MODEL_PATH" ]; then
            echo "Model already present at $MODEL_PATH"
          else
            echo "Downloading Qwen3.6-35B-A3B IQ4_XS (~18.8GB)..."
            curl -L --retry 5 --retry-delay 10 -o "$MODEL_PATH" \
              "https://huggingface.co/bartowski/Qwen_Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen_Qwen3.6-35B-A3B-IQ4_XS.gguf"
            echo "Download complete."
          fi
        volumeMounts:
        - name: models
          mountPath: /models
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
EOF
```

Monitor the download (the file is ~18.8 GB — expect 5–15 min depending on
bandwidth):

```bash
# Watch the job status
kubectl get job download-llm -w

# Stream the downloader logs
kubectl logs -f job/download-llm

# Check actual file on NFS from control plane
watch -n10 'ls -lh /nfsexport/default-models-pvc-*/Qwen*.gguf 2>/dev/null'
```

---

### Step 4 — Delete the old llama-server (if running)

```bash
kubectl delete deployment llama-server --ignore-not-found
kubectl delete service llama-service --ignore-not-found
```

---

### Step 5 — Deploy llama-server with the new model

The llama.cpp server image supports Qwen3.6 via the `qwen35moe` architecture.
Key flags:
- `-m` — path to the GGUF inside the container
- `--n-gpu-layers 999` — offload all layers to GPU (A10G handles the full IQ4_XS)
- `--ctx-size 8192` — context window (increase if KV cache fits; max 262 144)
- `--thinking` — leave the model's CoT reasoning enabled (responses start with `<think>...</think>`)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llama-server
  template:
    metadata:
      labels:
        app: llama-server
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: models-pvc
      containers:
      - name: llama-server
        image: ghcr.io/ggml-org/llama.cpp:server-cuda
        args:
        - --model
        - /models/Qwen_Qwen3.6-35B-A3B-IQ4_XS.gguf
        - --host
        - "0.0.0.0"
        - --port
        - "8080"
        - --n-gpu-layers
        - "999"
        - --ctx-size
        - "8192"
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: models
          mountPath: /models
        resources:
          requests:
            nvidia.com/gpu: 1
          limits:
            nvidia.com/gpu: 1
---
apiVersion: v1
kind: Service
metadata:
  name: llama-service
spec:
  selector:
    app: llama-server
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP
EOF
```

Wait for the pod to reach Running state (model loading takes ~30–60 seconds after
the pod starts):

```bash
kubectl get pod -l app=llama-server -w

# Watch model load progress
kubectl logs -f deployment/llama-server
```

---

### Step 6 — Test the model

```bash
# Get the ClusterIP
LLAMA_IP=$(kubectl get svc llama-service -o jsonpath='{.spec.clusterIP}')

# Health check
curl -s http://$LLAMA_IP:8080/health | jq .

# Chat — Qwen3.6 uses the same OpenAI-compatible /v1/chat/completions endpoint
# The <think>...</think> block appears in the content before the answer
curl -s http://$LLAMA_IP:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [
      {"role": "system", "content": "You are a helpful Kubernetes assistant."},
      {"role": "user", "content": "What is a PersistentVolumeClaim and when would you use one?"}
    ],
    "max_tokens": 512,
    "temperature": 0.6
  }' | jq -r '.choices[0].message.content'
```

> **Tip:** Qwen3.6 reasons by default. The model will emit `<think>…</think>`
> before the final answer. To suppress the thinking block and get just the
> answer, add `"chat_template_kwargs": {"thinking": false}` to the request body,
> or pass `--no-thinking` to the server args.

---

### Choosing a different quantization

If you have VRAM pressure (e.g. large context) or want higher quality:

| Quant | File size | Use case |
|---|---|---|
| Q4_K_M | 21.4 GB | Best quality that fits; ~2.5 GB KV cache headroom |
| **IQ4_XS** | **18.8 GB** | **Recommended — balanced quality/headroom** |
| Q3_K_XL | 17.3 GB | More KV cache headroom, slightly lower quality |
| Q3_K_M | 16.2 GB | Low quality, use only if you need >8K context |

To switch quants, change the filename in both the download job and the
deployment args, then run Steps 2–5 again. The old GGUF file will remain on
the PVC until you manually delete it.

