# Pod的基础


## 一、简介

pod在整个生命周期中被系统定义为各种状态，熟悉pod的各种状态对于理解如何设置pod的调度策略、重启策略都是很有必要的。

## 二、pod状态

- Pending：API Server已经创建该Pod，但在Pod内还有一个或多个容器的镜像没有创建，包括正在下载镜像的过程
- Running：Pod内所有容器均已创建，且至少有一个容器处于运行状态。正在启动状态或重启状态
- Succeeded：Pod内所有容器均成功执行后退出，且不会再重启
- Failed：Pod内所有容器均已退出，但至少有一个容器退出为失败状态，退出码不为0
- Unknown：由于某种原因无法获取该Pod的状态，可能由于网络通信不畅导致（无法连接API Server）

## 三、Pod重启策略

pod的重启策略（RestartPolicy）应用于Pod内的所有容器，并且仅在Pod所处的Node上由kubelet进行判断和重启操作。当某个容器异常退出或健康检查失败时，kubelet会根据重启策略来进行相应的操作。

- Always：默认策略，当容器失效时，由kubelet自动重启容器
- OnFailure：当容器终止运行且退出码不为0时，由kubelet自动重启该容器
- Never：不论容器的运行状态都不重启

kubelet重启容器的时间间隔以*sync-frequency*乘以2来计算，例如1、2、4、8倍等，最长5min，并且在成功重启后10min后重置该时间。

每种控制器对pod的重启策略要求：

- RC和DaemonSet：必须为Always，需要保证容器持续运行
- Job：OnFailure或Never，确保容器执行完成后不再重启
- kubelet：在pod失效后重启，不论将RestartPolicy设置为什么值，也不会对pod进行健康检查



*常见的状态转换场景（最终状态）*

| pod包含的容器数 | pod当前的状态 | 发生事件    | always  | OnFailure | Never   |
| --------------- | ------------- | ----------- | ------- | --------- | ------- |
| 1               | running       | 成功退出    | running | succeed   | succeed |
| 1               | running       | 失败退出    | running | running   | failed  |
| 2               | running       | 1个失败退出 | running | running   | running |
| 2               | running       | oom         | running | running   | failed  |

## 四、健康检查

- **LivenessProbe存活探针**：判断容器是否存活（running状态）。如果探针探测到容器不健康，kubelet会杀掉容器，并根据容器的重启策略处理。如果容器不包含存活探针，那么会认为容器一直健康。
- **ReadinessProbe就绪探针**：判断容器服务是否可用（ready状态），达到ready状态的pod才能接受请求。如果在运行过程中ready状态变为`false`，则系统自动将其从service的后端endpoint列表中隔离出去，后续再把恢复到ready状态的pod加回到endpoint列表。这样就能保证客户端再访问service时不会被转发到服务不可用的pod实例上。

三种实现方式：

- ExecAction：在容器内部执行命令，如果命令的状态码返回0，则表明容器健康。

  ```yaml
  livenessProbe:
  	exec:
  		command:
  		- cat
  		- /tmp/health
  ```

  

- TCPSocketAction：通过容器的`IP`地址和端口号`Port`执行TCP检查，如果能够建立TCP连接，则表明容器健康

  ```yaml
  livenessProbe:
  	tcpSocket:
  		port: 80
  ```

  

- HTTPGetAction：通过容器的IP地址、端口号及路径调用HTTP Get方法，如果响应的状态码大于等于200且小于400，则认为容器健康

  ```yaml
  livenessProbe:
  	httpGet:
  		path: /_status/healthz
  		port: 80
  ```

对于每种探测方式，都需要设置参数

- `initialDelaySeconds`：启动容器后进行首次健康检查的等待时间
- `timeoutSeconds`：健康检查发送请求后等待响应的超时时间
