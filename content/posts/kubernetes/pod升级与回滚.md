---
title: "Pod升级与回滚"
date: 2021-03-24T22:51:40+08:00
draft: false

tags: ['kubernetes','pod']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

## 一、简介

当集群中的某个服务需要升级时，我们需要停止目前与该服务的相关的所有pod，然后下载新版本镜像并创建新的pod。如果集群规模比较大，则这个工作就会很麻烦。kubernetes提供了滚动升级功能来解决这个问题。

## 二、Deployment的升级

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

当pod的镜像需要被升级为`nginx:1.9.1`时，可以通过`kubectl set image`命令

```
kubectl set image deployment/nginx-deploymnet nginx=nginx:1.9.1
```

或通过`kubectl edit`修改Deployment配置。

在Deployment的定义中，可以通过`spec.strategy`指定Pod更新的策略，目前支持`Recreate`（重建）和`RollingUpdate`（滚动更新），默认值为滚动更新。

- Recreate：表示Deployment在更新pod时，会先杀掉所有正在运行的Pod，然后创建新的Pod
- RollingUpdate：会以滚动更新的方式逐个更新Pod。
  + spec.strategy.rollingUpdate.maxUnavailable：用于指定Deployment在更新过程中不可用状态的Pod数量上限。
  + spec.strategy.rollingUpdate.maxSurge：用于指定Deployment更新Pod的过程中Pod总数超过Pod期望副本数部分的最大值。

**多重更新（Rollover）**

如果Deployment的上一次更新正在进行，此时用户再次发起Deployment的更新操作，那么Deployment会为每一次更新都创建一个ReplicaSet，而每次在新的ReplicaSet创建成功后，会逐个增加Pod副本数，同时将之前正在扩容的ReplicaSet停止扩容，并将其加入旧版本ReplicaSet列表中，然后开始缩容至0的操作。

## 三、Deployment的回滚

可以使用`kubectl rollout history`命令检查Deployment部署的历史记录。

```
kubectl rollout history deployment/nginx-deployment
```

注意：这里需要在新建Deployment时使用`--record`参数。

如果需要查看特定版本的详细信息，则可以加上`--revision=<N>`参数。

撤销本次发布并回滚到上一个部署版本

````
kubectl rollout undo deployment/nginx-deployment
````

当然，也可以使用`--to-revision`参数指定回滚到的部署版本号。

## 四、暂停和恢复Deployment的部署操作

对于一次复杂的Deployment配置修改，为了避免频繁触发Deployment的更新操作，可以先暂停Deployment的更新操作，然后进行配置修改，再恢复Deployment，一次触发完整的更新操作。

通过使用`kubectl rollout pause`暂停Deployment的更新操作

```
kubectl rollout pause deployment/nginx-deployment
```

通过使用`kubectl rollout resume`恢复操作

```
kubectl rollout resume deploy/nginx-deployment
```

## 五、其他更新操作

1、RC的滚动更新

- `kubectl rolling-update`命令，通过配置文件
  - RC名字不与旧RC相同；在selector中应至少有一个Label与旧RC的Label不同，以标识其为新RC。
  - `kubectl rolling-update redis-master -f redis-master-ctl-v2.yaml`
- `kubectl rolling-update`命令，不通过配置文件
  - `kubectl rolling-update redis-master --image=redis-master:2.0`
  - 执行结果是旧RC被删除，新的RC将使用旧RC的名称

2、DaemonSet的更新策略

- OnDelete：默认的升级策略，新的Pod并不会自动创建，直到用户手动删除旧版本的Pod，才触发新建操作。
- RollingUpdate：整个过程和Deployment类似，但不支持查看DaemonSet的更新历史记录；不能通过`rollback`回滚，必须通过再次提交旧版本配置的方式实现。

3、Statefulset的更新策略

实现了RollingUpdate、OnDelete和Paritioned策略。

`Partition:3`表示索引3以上的对象更新。