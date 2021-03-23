# Pod调度


## 一、简介

在大多数情况下，我们不关心pod会被调度到哪个节点，只关心pod是否被成功调度到集群的一个可用节点。但是，在真实生产环境中存在一种需求：希望某种pod全部运行在一个或一些节点上。比如需要ssd的pod都运行在具有ssd磁盘的目标节点上。

## 二、全自动调度

`deployment`或`rc`的主要功能之一就是自动部署一个容器应用的多份副本，以及持续监控副本的数量，在集群中始终维持用户指定的副本数量。

```yaml
nginx-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: 
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app: nginx
  replicas: 3
  template:
    metadata:
      labels: 
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
```

使用`kubectl create`命令创建这个`deployment`：

```
# kubectl create -f nginx-deployment.yaml
deployment "nginx-deployment" created
```

可以看到`Deployment`已经创建好3个副本，并且所有副本都是最新可用的。从调度策略上来说，这3个`pod`由系统全自动完成调度，用户无法干预调度过程和结果。

## 三、NodeSelector：定向调度

通过`Node`的标签（Label）和`Pod`的`nodeSelector`属性相匹配来讲`Pod`调度到指定的一些`Node`上。

1、通过`kubectl label`命令给目标`Node`打上一些标签：

```
kubectl label nodes <node-name> <label-key>=<label-value>
```

2、在`Pod`的定义中加上`nodeSelector`的设置

```yaml
apiVersion: v1
kind: ReplicationController
metadata:
  name: redis-master
  labels:
    name: redis-master
spec:
  replicas: 3
  selector:
    name: redis-master
  template:
    metadata:
      labels: 
        name: redis-master
    spec:
      containers:
      - name: master
        image: reids-master
        ports:
        - containerPort: 6379
      nodeSelector:	# 节点标签选择器
        zone: north
```

如果给多个`Node`都定义了相同的标签，则`scheduler`会根据调度算法从`Node`组中挑选一个可用的`Node`进行调度。

除了用户可以自行给`Node`添加标签，`kubernetes`也会给`Node`预定义一些标签。

- kubernetes.io/hostname
- kubernetes.io/os
- kubernetes.io/arch

## 四、NodeAffinity：Node亲和性调度

`NodeAffinity`为Node亲和性的调度策略，是用于替换`NodeSelector`的全新调度策略。目前有两种节点亲和性表达。

- **RequiredDuringSchedulingIgnoredDuringExecution**：必须满足指定的规则才能调度Pod到Node上，相当于硬限制。
- **PreferredDuringSchedulingIgnoredDuringExecution**：强调优先满足指定规则，调度器会尝试调度Pod到Node上，但不强求，相当于软限制。多个优先级规则还可以设置权重(weight)值，以定义执行的先后顺序。

**IgnoredDuringExecution**：如果一个Pod所在的结点在Pod运行期间标签发生了变更，不再符合Pod的结点亲和性需求，则系统将忽略Node上的Label变化，该Pod能继续在该节点上运行。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: with-node-affinity
spec:
  affinity:
    nodeAffinity: # 要求只在amd64的节点上运行
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: beta.kubernetes.io/arch
            operator: In
            values:
            - amd64
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1 # 尽量运行在磁盘类型为ssd的节点上
        preference:
          matchExpressions:
          - key: disk-type
            operator: In
            values:
            - ssd
   containers:
   - name: with-node-affinity
     image: pause:2.0
```

`NodeAffinity`语法支持的操作符包括`In`、`NotIn`、`Exists`、`DoesNotExist`、`Gt`、`Lt`。

`NodeAffinity`规则设置的注意事项：

- 如果同时定义了`nodeSelector`和`nodeAffinity`，那么必须两个条件都得到满足，Pod才能最终运行在指定的Node上
- 如果`nodeAffinity`指定了多个`nodeSelectorTerms`，那么其中一个能够匹配成功即可
- 如果`nodeSelectorTerms`中有多个`matchExpressions`，则一个节点必须满足所有`matchExpressions`才能运行Pod。

## 五、PodAffinity：Pod亲和与互斥调度策略

如果在具有标签相同的Node上运行了一个或多个符合条件的Pod，那么Pod应该运行在这个Node上。

**topologyKey**：节点所属的`topoloty`

- kubernets.io/hostname
- failure-domain.beta.kubernetse.io/zone
- failure-domain.beta.kubernets.io/region

pod的亲和与互斥的条件设置也是**RequiredDuringSchedulingIgnoredDuringExecution**和**PreferredDuringSchedulingIgnoredDuringExecution**。

Pod的亲和性被定义在`podAffinity`，Pod的互斥性被定义在`podAntiAffinity`。

1、参考目标Pod

创建一个名为`pod-flag`的pod，带有标签`security=S1`和`app=nginx`。

```yaml
apiVerson: v1
kind: Pod
metadata:
  name: pod-flag
  labels: 
    security: "S1"
    app: "nginx"
spec:
  containers:
  - name: nginx
    image: nginx
```

2、Pod的亲和性调度

```yaml
apiVerson: v1
kind: Pod
metadata:
  name: pod-affinity
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: security
            operator: In
            values:
            - S1
        topologyKey: kubernets.io/hostname
  containers:
  - name: with-pod-affinity
    image: pause:2.0
```

3、Pod的互斥性调度

```yaml
apiVerson: v1
kind: Pod
metadata:
  name: anti-affinity
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: security
            operator: In
            values:
            - S1
        topologyKey: failure-domain.beta.kubernets.io/zone
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: security
            operator: In
            values:
            - nginx
        topologyKey: kubernets.io/hostname
  containers:
  - name: anti-pod-affinity
    image: pause:2.0
```

新pod与`security=S1`的pod为同一个`zone`，但不与`app=nginx`的Pod为同一个`zone`。

topologyKey的限制（出于性能和安全方面考虑）：

- 在Pod亲和性和RequiredDuringScheduing的Pod互斥性的定义中，不允许使用空的topologyKey。
- 如果Admission Controller包含了`LimitPodHardAntiAffinityTopology`，那么针对`Required DuringScheduling`的Pod互斥性定义就被限制为`kubernetes.io/hostname`，要使用自定义的`topologyKey`就要改写或禁用该控制器。
- 在`PreferredDruingScheduling`类型的Pod互斥性定义中，空的`topologyKey`会被解释为`kubernets.io/hostname`、`failure-domain.beta.kubernetse.io/zone`、`failure-domain.beta.kubernets.io/region`的组合。
- 如果不是上述情况，就可以采用任意合法的`topologyKey`。

`PodAffinity`规则设置的注意事项：

- 除了设置`Label Selector`和`topologyKey`，用户还可以指定`Namespace`列表来进行限制，同样，使用`Label Selector`对`Namespace`进行选择。
- 在所有关联`requiredDuringSchedulingIgnoredDuringExecution`的`matchExpressions`全部满足之后，系统才能将Pod调度到某个Node上。

## 六、Taints和Tolerations（污点和容忍）

在Node上设置一个或多个Taint之后，除非Pod明确声明能够容忍这些污点，否则无法在这些Node上运行。Toleration是Pod的属性，让Pod能够运行在标注了taint的Node上。

```
# kubectl taint nodes node1 key=value:NoSchedule
```

然后在pod上声明toleration。

```yaml
tolerations:
- key: "key"
  operator: "Equal"
  value: "value"
  effect: "NoSchedule"
  
tolerations:
- key: "key"
  operator: "Exists"
  effect: "NoSchedule"
```

如果不指定`operator`，默认值为`Equal`。空的key配合Exists能够匹配所有键和值。空的effect能够匹配所有的effect。

- NoSchedule：不调度
- PreferNoSchedule：不优先调度
- NoExecute：不运行，已经在这个节点上的Pod会被驱逐。

## 七、Pod Priority Preemption：Pod优先级调度

优先级抢占调度策略的核心行为分别是驱逐（Eviction）和抢占（Preemption）。Evection是kubelet行为，即当一个Node发生资源不足情况时，该节点上的kubelet进程会发生驱逐动作，此时kubelet会综合考虑Pod的优先级、资源申请量与实际使用量等信息计算哪些Pod需要被驱逐；当同样优先级的Pod需要被驱逐时，实际使用的资源量超过申请量最大倍数的高耗能Pod会被首先驱逐。

**服务质量等级Qos：**

- Guaranteed：pod设置了`limit`或`limit=request`
- Burstable：pod里的一个容器`limit！=request`
- Best-Effort：`limit`和`request`均未设置

1、创建PriorityClasses

```yaml
apiVersion: scheduling.k8s.io/v1beta1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "This priority class should be used for service pods only"
```

2、可以在任意pod中引用优先级类别

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    env: test
spec:
  containers:
  - name: nginx
    image: nginx
    imagePullPolicy: IfNotPresent
  priorityClassName: high-priority
```

## 八、其他情况

1、DaemonSet：在每个Node上都调度一个Pod

2、Job和CronJob的批处理调度，可以设置任务数`completions`和并行度`parallelism`