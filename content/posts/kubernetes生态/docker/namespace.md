---
title: "Linux六大Namespace"
date: 2022-03-07T13:28:41+08:00
draft: false

tags: ['linux','namespace']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

云计算领域最火的莫过于“容器”，而提到容器，就不得不提Docker，可以说Docker已经是容器的代名词。

容器其实是一种沙盒技术，顾名思义，沙盒就是能够像集装箱一样，把应用“装”起来的技术。这样，应用和应用之间就有了边界，不互相干扰。

而我们通常会把容器技术和虚拟化技术做对比，应该会常常看到这样一张图

![容器和虚拟化对比图](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/28/容器和虚拟化对比图.jpg)

左边的图，画出了虚拟机的工作原理。其中，`Hypervisor`是虚拟机的重要组成部分，通过硬件虚拟化功能，模拟出了运行一个操作系统需要的各种硬件，比如CPU、内存、I/O设备等，然后，它在这些虚拟的硬件上安装了一个新的操作系统，即Guest OS。

而容器是进程级隔离，依靠`Namespace`机制实现进程间隔离，`Cgroups`实现进程资源限制。

## 一、Linux Namespace

Linux Namespace是Kernel的一个功能，可以隔离一系列的系统资源，比如PID(Process ID)、User ID、Network等。命名空间建立系统不同的视图，从用户的角度来看，每个命名空间就像是一台独立的Linux计算机一样，有自己的init进程(PID为1)。

当前Linux一共实现了6种不同类型的[`Namespace`](https://lwn.net/Articles/531114/)：

| Namespace类型 | 系统调用参数  | 内核版本 |
| ------------- | ------------- | -------- |
| Mount         | CLONE_NEWNS   | 2.4.19   |
| UTS           | CLONE_NEWUTS  | 2.6.19   |
| IPC           | CLONE_NEWIPC  | 2.6.19   |
| PID           | CLONE_NEWPID  | 2.6.24   |
| Network       | CLONE_NEWNET  | 2.6.29   |
| User          | CLONE_NEWUSER | 3.8      |

Namespace的API主要使用如下3个系统调用：

- `clone()`创建新进程。根据系统调用的参数判断哪些类型的Namespace被创建，而它的子进程也会被添加到这些Namespace中
- `unshare()`将进程移除某个Namespace
- `setns()`将进程加入到Namespace中

### 1.1、`UTC Namespace`

`UTC Namespace`主要用来隔离`nodename`和`domainname`两个系统标识。在`UTC Namespace`中，每个Namespace允许有自己的`hostname`。

我们写一个`UTC Namespace`的例子

```go
package main

import (
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		panic(err)
	}
}
```

`exec.Command("sh")`用来指定被`fork`处理的新进程的初始命令，默认使用`sh`来执行。然后就是设置系统调用参数，用`CLONE_NEWUTS`标识符去创建一个`UTC Namespace`。

执行`go run main.go`，使用`pstree -pl`查看系统中进程之间的关系。

```text
sshd(1194)─┬─sshd(22904)───bash(22915)───go(23058)─┬─main(23075)─┬─sh(23078)
           │            │                                       │             ├─{main}(23076)
           │            │                                       │             └─{main}(23077)
           │            │                                       ├─{go}(23059)
           │            │                                       ├─{go}(23060)
           │            │                                       ├─{go}(23061)
           │            │                                       ├─{go}(23074)
           │            │                                       └─{go}(23079)
```

输出当前的PID

```shell
# echo $$
23078
```

验证一下父进程和子进程是否在同一`UTC Namespace`

```shell
# readlink /proc/23075/ns/uts
uts:[4026531838]
# readlink /proc/23078/ns/uts
uts:[4026532284]
```

可以看到它们确实不在同一个`UTC Namespace`中。

由于`UTC Namespace`对`hostname`做了隔离，所以在这个环境中修改`hostname`应该不影响外部主机。

在shell环境下执行命令

```shell
# hostname -b golang
# hostname
golang
```

在外部环境下执行命令

```shell
# hostname
container
```

可以看到，外部的`hostname`确实没有被内部的修改影响到。

### 1.2、`IPC Namespace`

`IPC`全称为`Inter-Process Communication`，是`Unix/Linux`下进程通信的一种方式，`IPC`有共享内存、信号量、消息队列等方法。为了隔离进程，也需要把`IPC Namespace`隔离开，这样，只有同一个命名空间下的进程才能够互相通信。

```go
package main

import (
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		panic(err)
	}
}
```

我们在原先的代码仅做一点改动，增加`CLONE_NEWIPC`，希望创建`IPC Namespace`。

在宿主机上打开一个`shell`

```shell
# 查看现有的ipc Message Queues
# ipcs -q

------ Message Queues --------
key        msqid      owner      perms      used-bytes   messages

# 在全局创建一个ipc的队列，队列id为0
# ipcmk -Q
Message queue id: 0

# 查看刚刚新建的全局队列的信息
# ipcs -q

------ Message Queues --------
key        msqid      owner      perms      used-bytes   messages
0xad7e5e0d 0          root       644        0            0
```

然后，我们再执行`main.go`，在sh下查看ipc队列

```shell
# go run main.go
sh# ipcs -q

------ Message Queues --------
key        msqid      owner      perms      used-bytes   messages
```

可以看到，在新创建的`Namespace`看不到宿主机已经创建的`message queue`。同样，在新创建的`Namespace`里创建的队列，在全局中也无法看到。

### 1.3、`PID Namespace`

`PID Namespace`是用来隔离进程ID的，同一个进程，在`Namespace`里和在外部有着不同的进程`PID`。

```go
package main

import (
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC | syscall.CLONE_NEWPID,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		panic(err)
	}
}
```

添加一个`CLONE_NEWPID`，代表`fork`出来的子进程创建自己的`PID Namespace`。

用`pstree -pl`在宿主机上查看进程树，找到真实的`PID`，然后在`PID Namespace`打印`PID`

```shell
# 一个shell中运行
# go run main.go
sh# echo $$
1

# 另一个shell中查看进程树
# pstree -pl
sshd(1194)─┬─sshd(22904)───bash(22915)───go(23192)─┬─main(23212)─┬─sh(23215)
```

可以看到在`PID Namespace`打印`PID`为1，也就是说`23212`这个`PID`被映射为1。

>  这里不能用`ps`查看，因为`ps`和`top`等命令是使用 `/proc`的内容。

### 1.4、`Mount Namespace`

程序运行时可以将挂载点和系统分离，使用这个功能，我们可以达到`chroot`的功能。

`Mount Namespace`用来隔离各个进程看到的挂载点视图，在不同的`Namespace`的进程中，看到的文件系统的层次是不一样的。

在`Mount Namespace`中调用`mount()`和`unmount()`仅仅只会影响当前`Namespace`内的文件系统，对全局文件系统是不影响的。

```go
package main

import (
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:
			syscall.CLONE_NEWUTS |
			syscall.CLONE_NEWIPC |
			syscall.CLONE_NEWPID |
			syscall.CLONE_NEWNS,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		panic(err)
	}
}
```

同样增加一点小改动`syscall.CLONE_NEWNS`，然后运行代码，查看`/proc`的文件内容。

```shell
# ls /proc
1      15766  16043  20     22915  23456  27601  43   8050       crypto       kallsyms    mounts        sys
10     15770  16061  20803  23     23498  27889  44   828        devices      kcore       mtrr          sysrq-trigger
1045   15782  16079  20822  23192  235    27999  45   9          diskstats    keys        net           sysvipc
1051   15800  16097  20878  23212  23521  30     46   94         dma          key-users   pagetypeinfo  timer_list
1061   15887  16115  20882  23215  23524  31     468  955        driver       kmsg        partitions    timer_stats
1062   15906  1612   20896  233    23526  31770  472  957        execdomains  kpagecount  sched_debug   tty
11     15907  16185  20914  23339  236    32     478  acpi       fb           kpageflags  schedstat     uptime
1194   15908  17     20999  23387  24     33     540  buddyinfo  filesystems  loadavg     scsi          version
13     15910  18     21     234    241    350    59   bus        fs           locks       self          vmallocinfo
14     15999  19     22     23442  247    372    6    cgroups    interrupts   mdstat      slabinfo      vmstat
15     16     19352  227    23444  257    4      7    cmdline    iomem        meminfo     softirqs      zoneinfo
15750  16012  19898  22900  23446  258    403    760  consoles   ioports      misc        stat
15754  16021  2      22904  23453  27588  41     8    cpuinfo    irq          modules     swaps
```

因为这里的`/proc`还是宿主机的，所以我们用`mount`到`Namespace`里

```shell
# mount -t proc proc /proc
# ls /proc
1          devices      ioports     locks         sched_debug    sysvipc
4          diskstats    irq         mdstat        schedstat      timer_list
acpi       dma          kallsyms    meminfo       scsi           timer_stats
buddyinfo  driver       kcore       misc          self           tty
bus        execdomains  keys        modules       slabinfo       uptime
cgroups    fb           key-users   mounts        softirqs       version
cmdline    filesystems  kmsg        mtrr          stat           vmallocinfo
consoles   fs           kpagecount  net           swaps          vmstat
cpuinfo    interrupts   kpageflags  pagetypeinfo  sys            zoneinfo
crypto     iomem        loadavg     partitions    sysrq-trigger
```

可以看到，数字少了很多，这样就能够运行`ps`命令了

```shell
# ps -ef
UID        PID  PPID  C STIME TTY          TIME CMD
root         1     0  0 13:53 pts/1    00:00:00 sh
root         5     1  0 13:59 pts/1    00:00:00 ps -ef
```

可以看到，`sh`进程时`PID`为1的进程，当前`Mount Namespace`的`mount`和外部空间是隔离的。

### 1.5、`User Namespace`

`User Namespace`主要是隔离用户的用户组`ID`，也就是说，一个进程的`User ID`和`Group ID`在命名空间内外可以是不同的。

比如，在宿主机上以一个非`root`用户创建的`User Namespace`，在`User Namespace`里被映射为`root`用户。

```go
package main

import (
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:
			syscall.CLONE_NEWUTS |
			syscall.CLONE_NEWIPC |
			syscall.CLONE_NEWPID |
			syscall.CLONE_NEWNS |
			syscall.CLONE_NEWUSER,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		panic(err)
	}
}
```

同样增加`syscall.CLONE_NEWUSER`。

首先以`root`用户运行程序

```shell
# 查看当前用户和用户组
# id
uid=0(root) gid=0(root) groups=0(root)
```

我的系统是CentOS7，所以在执行前需要做一些工作。

```shell
# 需要开启User Namespace
# grubby --args="user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"

# 重启
# reboot

# echo 640 > /proc/sys/user/max_user_namespaces
```

之后就可以正常运行程序了

```shell
# go run main.go
sh$ id
uid=65534 gid=65534 groups=65534
```

可以看到，它们的`UID`不同，说明`User Namespace`生效了。

### 1.6、`Network Namespace`

`Network Namespace`用于隔离网络资源(/proc/net、IP地址端口、网卡、路由等)，让每个容器都有自己独立的（虚拟）网络设备，每个网络命名空间都有自己的路由表，iptables。

```go
package main

import (
	"log"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	cmd := exec.Command("sh")

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS |
			syscall.CLONE_NEWIPC |
			syscall.CLONE_NEWPID |
			syscall.CLONE_NEWNS |
			syscall.CLONE_NEWUSER |
			syscall.CLONE_NEWNET,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
        panic(err)
	}
}
```

首先在宿主机上查看自己的网络设备

```shell
# ifconfig
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 172.27.158.184  netmask 255.255.240.0  broadcast 172.27.159.255
        inet6 fe80::216:3eff:fe19:d2fc  prefixlen 64  scopeid 0x20<link>
        ether 00:16:3e:19:d2:fc  txqueuelen 1000  (Ethernet)
        RX packets 4583  bytes 3471561 (3.3 MiB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 2986  bytes 1983980 (1.8 MiB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        inet6 ::1  prefixlen 128  scopeid 0x10<host>
        loop  txqueuelen 1000  (Local Loopback)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```

可以看到有`eth0`和`lo`网络设备，然后运行程序

```shell
# go run main.go
sh$ ifconfig
sh$
```

我们发现，在`Network Namespace`里什么网络设备都没有，这样`Network Namespace`和宿主机之间网络是隔离的。

## 二、Linux Cgoups

`Linux Cgoups`全称是`Linux Control Group`，它的主要作用就是限制一个进程组能够使用的资源上限，包括CPU、内存、磁盘、网络等。

在Linux中，Cgroups给用户暴露出来的操作接口是文件系统，即它以文件和目录的方式组织在`/sys/fs/cgroup`路径下。

```shell
# mount -t cgroup
cgroup on /sys/fs/cgroup/systemd type cgroup (rw,nosuid,nodev,noexec,relatime,xattr,release_agent=/usr/lib/systemd/systemd-cgroups-agent,name=systemd)
cgroup on /sys/fs/cgroup/net_cls,net_prio type cgroup (rw,nosuid,nodev,noexec,relatime,net_prio,net_cls)
cgroup on /sys/fs/cgroup/memory type cgroup (rw,nosuid,nodev,noexec,relatime,memory)
cgroup on /sys/fs/cgroup/cpuset type cgroup (rw,nosuid,nodev,noexec,relatime,cpuset)
cgroup on /sys/fs/cgroup/perf_event type cgroup (rw,nosuid,nodev,noexec,relatime,perf_event)
cgroup on /sys/fs/cgroup/freezer type cgroup (rw,nosuid,nodev,noexec,relatime,freezer)
cgroup on /sys/fs/cgroup/hugetlb type cgroup (rw,nosuid,nodev,noexec,relatime,hugetlb)
cgroup on /sys/fs/cgroup/blkio type cgroup (rw,nosuid,nodev,noexec,relatime,blkio)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpuacct,cpu)
cgroup on /sys/fs/cgroup/devices type cgroup (rw,nosuid,nodev,noexec,relatime,devices)
cgroup on /sys/fs/cgroup/pids type cgroup (rw,nosuid,nodev,noexec,relatime,pids)
```

可以看到，在`/sys/fs/cgroup`下面有很多`cpu`、`memory`这样的子目录，也就称为子系统`subsystem`，它是一组资源控制模块，一般包含如下几项：

- `net_cls`：将cgroup中进程产生的网络包分类，以便Linux的tc(traffic controller)可以根据分类区分出来自某个cgroup的包并做限流或监控
- `net_prio`：设置cgroup中进程产生的网络流量的优先级
- `memory`：控制cgroup中进程的内存占用
- `cpuset`：在多核机器上设置cgroup中进程可以使用的cpu和内存
- `freezer`：挂起(suspend)和恢复(resume)cgroup中的进程
- `blkio`：设置对块设备(如硬盘)输入输出的访问控制
- `cpu`：设置cgroup中进程的CPU占用
- `cpuacct`：统计cgroup中进程的CPU占用
- `devices`：控制cgroup中进程对设备的访问

### 2.1、挂载cgroup

我们创建并挂载一个cgroup

```shell
# mkdir cgroup-test
# mount -t cgroup -o none,name=cgroup-test cgroup-test ./cgroup-test
# ls ./cgroup-test/
cgroup.clone_children  cgroup.event_control  cgroup.procs  cgroup.sane_behavior  notify_on_release  release_agent  tasks
```

挂载后我们能看到系统在这个目录下生成了一些默认的文件：

- cgroup.clone_children：cpuset的subsystem会读取这个配置文件，如果这个值是1(默认是0)，子cgroup才会继承父cgroup的cpuset的配置
- cgroup.event_control：监控状态变化和分组删除事件的配置文件
- cgroup.procs：树中当前节点cgroup的进程组ID
- notify_on_release和release_agent：notify_on_release标识这个cgroup最后一个进程退出时是否执行了release_agent，release_agent则是一个路径，通常用作进程退出后清理不再使用的cgroup
- task：标识该cgroup下的进程ID，如果把一个进程ID写入tasks文件中，便会将相应的进程加入到这个cgroup中

### 2.2、新建子cgroup

```shell
# mkdir cgroup-1
# mkdir cgroup-2
# ls
cgroup-1  cgroup.clone_children  cgroup.procs          notify_on_release  tasks
cgroup-2  cgroup.event_control   cgroup.sane_behavior  release_agent
# tree
.
├── cgroup-1
│   ├── cgroup.clone_children
│   ├── cgroup.event_control
│   ├── cgroup.procs
│   ├── notify_on_release
│   └── tasks
├── cgroup-2
│   ├── cgroup.clone_children
│   ├── cgroup.event_control
│   ├── cgroup.procs
│   ├── notify_on_release
│   └── tasks
├── cgroup.clone_children
├── cgroup.event_control
├── cgroup.procs
├── cgroup.sane_behavior
├── notify_on_release
├── release_agent
└── tasks

2 directories, 17 files
```

在挂载目录下创建文件夹时，操作系统会把文件夹标记为子cgroup，会继承父cgroup的属性

### 2.3、添加进程

把进程ID写入到cgroup节点的tasks文件中

```shell
[cgroup-1]# echo $$
1186
[cgroup-1]# sh -c "echo $$ >> tasks"
[cgroup-1]# cat /proc/1186/cgroup
12:name=cgroup-test:/cgroup-1
11:pids:/
10:devices:/
9:cpuacct,cpu:/
8:blkio:/
7:hugetlb:/
6:freezer:/
5:perf_event:/
4:cpuset:/
3:memory:/
2:net_prio,net_cls:/
1:name=systemd:/user.slice/user-0.slice/session-1.scope
```

可以看到，当前进程1186已经被加入到`cgroup-test:/cgroup-1`中了

### 2.4、限制资源

我们来写一个脚本

```shell
# while : ; do : ; done &
[1] 1448
```

使用`top`命令查看，可以看到CPU已经占满

```shell
# top
%Cpu(s):100.0 us,  0.0 sy,  0.0 ni,  0.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
```

然后我们通过cgroup限制这个进程资源

```shell
# mount | grep cpu
cgroup on /sys/fs/cgroup/cpuset type cgroup (rw,nosuid,nodev,noexec,relatime,cpuset)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpuacct,cpu)

# cd /sys/fs/cgroup/cpu
# ls
aegis                  cgroup.event_control  cpuacct.stat          cpu.cfs_period_us  cpu.rt_runtime_us  notify_on_release
assist                 cgroup.procs          cpuacct.usage         cpu.cfs_quota_us   cpu.shares         release_agent
cgroup.clone_children  cgroup.sane_behavior  cpuacct.usage_percpu  cpu.rt_period_us   cpu.stat           tasks

# 创建一个cgroup
# mkdir test-limit-cpu && cd test-limit-cpu/
# 设置cpu占用容量，意味着在每100ms时间内，该进程只能使用20ms的CPU时间
# echo 20000 > cpu.cfs_quota_us
# 将当前进程添加进cgroup中
# echo 1448 > tasks
```

通过`top`命令查看

```shell
# top
%Cpu(s): 20.5 us,  0.7 sy,  0.0 ni, 78.8 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
```

可以看到计算机的CPU使用率立刻降到了20%。

### 2.5、Docker使用Cgroup

Linux Cgroup的设计还是比较简单的，就是在子目录系统加上一组限制资源文件的组合。而对于Docker来说，只需要在每个子系统下面，为每个容器创建一个控制组(新建目录)，然后在启动容器进程后，把这个进程的PID填写到对应控制组的tasks文件中即可。

```shell
# docker run -itd -m 128m busybox
3da89b011026f40a22b22c9b9b8e15e5fb85045c6aa72f7b54406f141cd63157

# cd /sys/fs/cgroup/memory/docker/3da89b011026f40a22b22c9b9b8e15e5fb85045c6aa72f7b54406f141cd63157/
# cat memory.limit_in_bytes
134217728
```

可以看到，Docker通过为每个容器创建cgroup，并通过cgroup去配置资源限制和资源监控。

### 2.6、程序实现

```go
package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"strconv"
	"syscall"
)

const cgroupMountPath = "/sys/fs/cgroup/cpu"

func main() {
	if os.Args[0] == "/proc/self/exe" {
		// 容器进程
		fmt.Printf("current pid %d\n", syscall.Getpid())

		cmd := exec.Command("sh", "-c", "while : ; do : ; done")
		cmd.SysProcAttr = &syscall.SysProcAttr{}
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		err := cmd.Run()
		if err != nil {
			panic(err)
		}
	}

	cmd := exec.Command("/proc/self/exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS |
			syscall.CLONE_NEWPID |
			syscall.CLONE_NEWNS,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Start()
	if err != nil {
		panic(err)
	}

	// 得到fork出来进程映射在外部命名空间的pid
	fmt.Printf("%v\n", cmd.Process.Pid)

	// 在系统默认创建挂载了 cpu subsystem 上创建cgroup
	pidCgroup := path.Join(cgroupMountPath, "testcpulimit")
	os.Mkdir(pidCgroup, 0775)
	// 将容器进程加入到这个cgroup中
	ioutil.WriteFile(path.Join(pidCgroup, "tasks"), []byte(strconv.Itoa(cmd.Process.Pid)), 0644)
	// 限制cgroup使用
	ioutil.WriteFile(path.Join(pidCgroup, "cpu.cfs_quota_us"), []byte("20000"), 0644)

	cmd.Process.Wait()
}
```

通过对cgroup的配置，将容器中`sh`进程的CPU占用限制到了20ms(20%)。

```shell
# top
%Cpu(s): 26.4 us,  1.4 sy,  0.0 ni, 72.2 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
PID USER      PR  NI    VIRT    RES    SHR S %CPU %MEM     TIME+ COMMAND
2668 root      20   0  113284   1208   1028 R 20.0  0.1   0:17.37 sh
```

## 三、Union File System

Union File System简称是UnionFS，把其他文件系统联合到一个联合挂载点的文件系统服务。

可能你会对之前提到的`Mount Namespace`产生混淆，`Mount Namespace`是容器进程对文件系统"挂载点"的认知，这就意味着，只有挂载这个操作发生后，进程的视图才会被改变。在此之前，新创建的容器会直接继承宿主机的各个挂载点。

### 3.1、chroot

在Linux操作系统中，`chroot`命令可以`change root file system`，即改变进程的根目录到你指定的位置。

它的使用方法也很简单。

假设，我们现在有一个`$HOME/test`目录，想要把它作为`/bin/bash`进程的根目录

1、首先创建一个`test`目录和几个`lib`文件夹

```shell
# mkdir -p test
# mkdir -p test/{bin,lib64,lib}
```

2、把bash命令拷贝到test目录下的bin路径下

```shell
# cp -v /bin/{bash,ls} $HOME/test/bin
‘/bin/bash’ -> ‘/root/test/bin/bash’
‘/bin/ls’ -> ‘/root/test/bin/ls’
```

3、把bash命令需要的所有so文件拷贝到对应的lib路径下。可以使用ldd命令找到so文件

```shell
# T=$HOME/test
# list="$(ldd /bin/ls | egrep -o '/lib.*\.[0-9]')"
# for i in $list; do cp -v "$i" "${T}${i}"; done
```

4、最后执行chroot命令，把`$HOME/test`目录作为`/bin/bash`进程的根目录

```shell
# chroot $HOME/test /bin/bash
```

这时，执行`./bin/ls /`命令，就会看到返回的是`$HOME/test`目录下的内容，而不是宿主机的内容。

对于被`chroot`的进程来说，它并不知道自己的根目录已经被修改了

### 3.2、aufs

aufs全称是Advanced Multi-Layered Unification Filesystem，主要功能就是将多个不同位置的目录联合挂载到同一个目录下。

例如，有两个文件夹A和B，他们分别有两个文件

```shell
# tree
.
├── A
│   ├── a
│   └── x
└── B
    ├── b
    └── x
```

然后，用联合挂载的方式，将这两个目录挂载到公共目录C上

```shell
# mkdir C
# mount -t aufs -o dirs=./A:./B none ./C
# tree ./C
./A
├── a
├── b
└── x
```

### 3.3、docker使用的aufs

查看docker使用的存储

```shell
# docker info
 Storage Driver: overlay2
  Backing Filesystem: extfs
  Supports d_type: true
  Native Overlay Diff: true
  userxattr: false
 Logging Driver: json-file
 Cgroup Driver: cgroupfs
 Cgroup Version: 1
```

可以看到docker使用的是`overlay2`，docker在Linux上提供几种存储驱动程序:

| Driver         | 描述                                                         |
| -------------- | ------------------------------------------------------------ |
| overlay2       | 是所有支持的Linux发行版的首选存储驱动程序                    |
| fuse-overlayfs | 仅适用于不提供rootless支持的主机上运行docker                 |
| btrfs和zfs     | 允许高级选项，如创建“快照”                                   |
| vfs            | 为了测试，并不能使用任何写时复制，性能较差，一般不用于生产   |
| aufs           | 适用于ubuntu18.06或更早版本                                  |
| deviemapper    | 需要`direct-lvm`，零配置但性能差，是以前的CentOS和RHEL中的存储驱动程序 |
| overlay        | 旧`overlay`驱动程序用于不支持“multiple-lowerdir”功能的内核   |

我们拉取镜像然后查看

```shell
# docker pull centos
# docker image inspect centos
"GraphDriver": {
            "Data": {
                "MergedDir": "/var/lib/docker/overlay2/25b7b27521d0dfa478b9173e0f39b726d914cebfb12a011d97093bf79f48201a/merged",
                "UpperDir": "/var/lib/docker/overlay2/25b7b27521d0dfa478b9173e0f39b726d914cebfb12a011d97093bf79f48201a/diff",
                "WorkDir": "/var/lib/docker/overlay2/25b7b27521d0dfa478b9173e0f39b726d914cebfb12a011d97093bf79f48201a/work"
            },
            "Name": "overlay2"
        },
        "RootFS": {
            "Type": "layers",
            "Layers": [
                "sha256:74ddd0ec08fa43d09f32636ba91a0a3053b02cb4627c35051aff89f853606b59"
            ]
        }
```

此时再rootfs的`layers`只有一层，接下来，以centos镜像为基础镜像，创建一个`changed-centos`的镜像。

```dockerfile
FROM centos

RUN echo "Hello World" > /tmp/newfile
```

然后编译镜像

```shell
# docker build -t changed-centos .
Sending build context to Docker daemon  5.632kB
Step 1/2 : FROM centos
 ---> 5d0da3dc9764
Step 2/2 : RUN echo "Hello World" > /tmp/newfile
 ---> Running in 56f851769616
Removing intermediate container 56f851769616
 ---> 9c6d811a36cd
Successfully built 9c6d811a36cd
Successfully tagged changed-centos:latest
```

然后查看生成的镜像信息

```shell
# docker image inspect changed-centos
"GraphDriver": {
            "Data": {
                "LowerDir": "/var/lib/docker/overlay2/25b7b27521d0dfa478b9173e0f39b726d914cebfb12a011d97093bf79f48201a/diff",
                "MergedDir": "/var/lib/docker/overlay2/1962f3c14c7b78c087c80042cd0076686137a2bf4ae4d989d797813569a895a0/merged",
                "UpperDir": "/var/lib/docker/overlay2/1962f3c14c7b78c087c80042cd0076686137a2bf4ae4d989d797813569a895a0/diff",
                "WorkDir": "/var/lib/docker/overlay2/1962f3c14c7b78c087c80042cd0076686137a2bf4ae4d989d797813569a895a0/work"
            },
            "Name": "overlay2"
        },
        "RootFS": {
            "Type": "layers",
            "Layers": [
                "sha256:74ddd0ec08fa43d09f32636ba91a0a3053b02cb4627c35051aff89f853606b59",
                "sha256:4f3b7a0aae6d9b57d111bd1eb2e99ca900a36e2370b47266859e6ca4d97dd1f0"
            ]
        }
```

可以看到`layers`新增一层

```shell
# docker history changed-centos
IMAGE          CREATED         CREATED BY                                      SIZE      COMMENT
9c6d811a36cd   2 minutes ago   /bin/sh -c echo "Hello World" > /tmp/newfile    12B       
5d0da3dc9764   3 months ago    /bin/sh -c #(nop)  CMD ["/bin/bash"]            0B        
<missing>      3 months ago    /bin/sh -c #(nop)  LABEL org.label-schema.sc…   0B        
<missing>      3 months ago    /bin/sh -c #(nop) ADD file:805cb5e15fb6e0bb0…   231MB
```

从输出中可以看到，image layer最上层仅有12B大小，也就是说`changed-centos`镜像仅占用了12B的磁盘空间。

## 四、总结

本文主要介绍了Docker运行的三大基石：Namespace、Cgroup和rootfs。

了解这些内容就能够清晰地明白docker和虚拟机的区别了，也就是说运行在Docker里的进程仍然需要宿主机的支持，比如内核版本等。
