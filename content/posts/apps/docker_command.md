---
title: "Docker命令大全"
date: 2021-02-12T19:26:01+08:00
draft: false

tags: ['docker']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

> Docker是一个虚拟环境容器，可以将你的开发环境、代码、配置文件等一并打包到这个容器中，并发布和应用到任意平台中。所以你需要知道一点docker的命令。

这里是关于docker的基础命令（第一节）

- 版本信息：查看docker的各项基础信息
- 仓库管理：管理镜像存储的仓库

# 版本信息

## info

`docker info`：显示Docker系统信息，包括镜像、容器数量和镜像仓库。

**语法**

```bash
docker info [OPTIONS]

Options:
  -f, --format string 显示返回值的模板文件
```

**实例**

```
Client:
 Context:    default
 Debug Mode: false
 Plugins:
  app: Docker App (Docker Inc., v0.9.1-beta3)
  buildx: Build with BuildKit (Docker Inc., v0.5.1-docker)

Server:
 Containers: 1
  Running: 1
  Paused: 0
  Stopped: 0
 Images: 1
 Server Version: 20.10.3
 Storage Driver: overlay2
  Backing Filesystem: xfs
  Supports d_type: true
  Native Overlay Diff: true
 Logging Driver: json-file
 Cgroup Driver: cgroupfs
 Cgroup Version: 1
 Plugins:
  Volume: local
  Network: bridge host ipvlan macvlan null overlay
  Log: awslogs fluentd gcplogs gelf journald json-file local logentries splunk syslog
 Swarm: inactive
 Runtimes: runc io.containerd.runc.v2 io.containerd.runtime.v1.linux
 Default Runtime: runc
 Init Binary: docker-init
 containerd version: 269548fa27e0089a8b8278fc4fc781d7f65a939b
 runc version: ff819c7e9184c13b7c2607fe6c30ae19403a7aff
 init version: de40ad0
 Security Options:
  seccomp
   Profile: default
 Kernel Version: 3.10.0-1160.15.2.el7.x86_64
 Operating System: CentOS Linux 7 (Core)
 OSType: linux
 Architecture: x86_64
 CPUs: 2
 Total Memory: 1.795GiB
 Name: localhost.localdomain
 ID: 4NYR:4KA5:NBOL:V6Y7:SE6H:B2R7:2LRD:FNIL:CK5J:4L4J:6K63:5RMO
 Docker Root Dir: /var/lib/docker
 Debug Mode: false
 Registry: https://index.docker.io/v1/
 Labels:
 Experimental: false
 Insecure Registries:
  127.0.0.0/8
 Live Restore Enabled: false
```

## version

`docker version`：显示Docker版本信息。

**语法**

```bash
docker version [OPTIONS]

Options:
  -f, --format string       显示返回值指定的模板文件
      --kubeconfig string	k8s配置文件
```

**实例**

```
Client: Docker Engine - Community
 Version:           20.10.3
 API version:       1.41
 Go version:        go1.13.15
 Git commit:        48d30b5
 Built:             Fri Jan 29 14:34:14 2021
 OS/Arch:           linux/amd64
 Context:           default
 Experimental:      true

Server: Docker Engine - Community
 Engine:
  Version:          20.10.3
  API version:      1.41 (minimum version 1.12)
  Go version:       go1.13.15
  Git commit:       46229ca
  Built:            Fri Jan 29 14:32:37 2021
  OS/Arch:          linux/amd64
  Experimental:     false
 containerd:
  Version:          1.4.3
  GitCommit:        269548fa27e0089a8b8278fc4fc781d7f65a939b
 runc:
  Version:          1.0.0-rc92
  GitCommit:        ff819c7e9184c13b7c2607fe6c30ae19403a7aff
 docker-init:
  Version:          0.19.0
  GitCommit:        de40ad0
```

> 通常刚安装完docker时，使用`docker version`来验证docker的client和server是否可用。如果server显示权限不足，可以通过`sudo docker`或 给docker添加sudo权限。

# 镜像仓库

## login

`docker login`：登录到一个Docker镜像仓库，如果未指定镜像仓库地址，默认为官方仓库。

**语法**

```bash
docker login [OPTIONS] [SERVER]

Options:
  -p, --password string		登录的密码
      --password-stdin 		使用标准输入输入密码
  -u, --username string		登录的用户名
```

**实例**

```
docker login -u 用户名 -p 密码
```

## logout

`docker logout`：登出一个Docker镜像仓库，如果没有指定镜像仓库地址，默认为官方仓库。

**语法**

```bash
docker logout [SERVER]
```

**实例**

```
docker logout
```

## pull

`docker pull`：从镜像仓库中拉取或者更新指定镜像。

**语法**

```bash
docker pull [OPTIONS] NAME[:TAG|@DIGEST]

Options:
  -a, --all-tags                下载镜像在仓库中的所有版本
      --disable-content-trust   忽略镜像的校验，默认开启
      --platform string       	如果服务器支持多平台，设置平台
  -q, --quiet				   静默拉取
```

**实例**

```
docker pull hello-world
docker pull hello-world -a
docker pull hello-wprld -q
```

## push

`docker push`：将本地的镜像上传到镜像仓库（已经登录到镜像仓库）。

**语法**

```bash
docker push [OPTIONS] NAME[:TAG]

Options:
  -a, --all-tags                推送本地所有打过tag的镜像
      --disable-content-trust   忽略镜像的检验，默认开启
  -q, --quiet				   静默上传
```

**实例**

```
docker push hello-world:v1
```

## search

`docker search`：从镜像仓库中查找镜像。

**语法**

```bash
docker search [OPTIONS] TERM

Options:
  -f, --filter filter   根据过滤的条件输出结果
      --format string   使用特定的模板输出搜索结果
      --limit int       最大搜索结果，默认25
      --no-trunc		显示完整的镜像描述
```

**实例**

```
docker search hello-world -f STARS=10 --limit=2

NAME                DESCRIPTION                                     STARS     OFFICIAL   AUTOMATED
hello-world         Hello World! (an example of minimal Dockeriz…   1380      [OK]
tutum/hello-world   Image to test docker deployments. Has Apache…   78                   [OK]
```

参数说明：

- NAME：镜像仓库源的名称
- DESCRIPTION：镜像的描述
- STARS：表示点赞，关注的个数
- OFFICIAL：是否是官方发布
- AUTOMATED：自动构建

## images

`docker images`：列出本地镜像

**语法**

```
docker images [OPTIONS] [REPOSITORY[:TAG]]

Options:
  -a, --all             列出本地所有的镜像（含中间映像层，默认情况下，过滤掉中间映像层）
      --digests         显示镜像的摘要信息
  -f, --filter filter   显示满足条件的镜像
      --format string   指定返回值的模板文件
      --no-trunc        显示完整的镜像信息
  -q, --quiet      只显示镜像ID
```

**实例**

```
docker images

REPOSITORY                                                    TAG                 IMAGE ID       CREATED         SIZE
registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase   v0.0.15-snapshot4   06db6ca72446   2 months ago    941MB
hello-world                                                   latest              bf756fb1ae65   13 months ago   13.3kB
```

## rmi

`docker rmi`：删除本地一个或多个镜像

**语法**

```
docker rmi [OPTIONS] IMAGE [IMAGE...]

Options:
  -f, --force      强制删除
      --no-prune   不移除该镜像的过程镜像，默认移除
```

**实例**

```
docker rmi hello-world -f
Untagged: hello-world:latest
Untagged: hello-world@sha256:31b9c7d48790f0d8c50ab433d9c3b7e17666d6993084c002c2ff1ca09b96391d
Deleted: sha256:bf756fb1ae65adf866bd8c456593cd24beb6a0a061dedf42b26a993176745f6b
Deleted: sha256:9c27e219663c25e0f28493790cc0b88bc973ba3b1686355f221c38a36978ac63
```

## tag

`docker tag`：标记本地镜像，将其归入某一仓库。

**语法**

```
docker tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]
```

**用法**

```
docker tag hello-world hello-world:v1
docker images hello-world
REPOSITORY    TAG       IMAGE ID       CREATED         SIZE
hello-world   latest    bf756fb1ae65   13 months ago   13.3kB
hello-world   v1        bf756fb1ae65   13 months ago   13.3kB
```

## build

`docker build`：使用Dockerfile创建镜像。

**语法**

```
docker build [OPTIONS] PATH | URL | -

Options:
      --add-host list           添加(host:ip)
      --build-arg list          设置镜像创建时的变量
      --cache-from strings      镜像缓存
      --cgroup-parent string    容器可选的父cgroup
      --compress                压缩构建上下文使用gzip
      --cpu-period int          限制cpu cfs周期
      --cpu-quota int           限制cpu cfs配额
  -c, --cpu-shares int          设置cpu使用权重
      --cpuset-cpus string      设置使用的cpu id
      --cpuset-mems string      设置使用的内存id
      --disable-content-trust   忽略校验，默认开启
  -f, --file string             指定要使用的Dockerfile路径，默认是'PATH/Dockerfile'
      --force-rm                设置镜像过程中删除中间容器
      --iidfile string          写入镜像id到文件
      --isolation string        使用容器隔离技术
      --label list              设置镜像使用的元数据
  -m, --memory bytes            设置内存最大值
      --memory-swap bytes       设置swap的最大值为内存+swap，-1表示不受限
      --network string          在构建期间设置RUN指令的网络模式，默认为"default"
      --no-cache                创建镜像过程中不使用缓存
      --pull                    尝试去更新镜像的最新版本
  -q, --quiet                   安静模式，成功后只输出镜像ID
      --rm                      设置镜像成功后删除中间容器
      --security-opt strings    安全选项
      --shm-size bytes          设置/dev/shm，默认值是64M
  -t, --tag list                镜像的名字及标签，通常为'name:tag'格式，可以在一次构建中为一个镜像设置多个标签
      --target string           设置指定构建步骤
      --ulimit ulimit           Ulimit选项
```

**用法**

```
docker build -t my-image:v1 .
```

## history

`docker history`：展示一个镜像的历史。

**语法**

```
docker history [OPTIONS] IMAGE

Options:
      --format string   指定模板输出
  -H, --human           以可读的格式打印镜像大小和日期，默认true
      --no-trunc        显示完整的提交记录
  -q, --quiet           仅列出提交记录的ID
```

**实例**

```
docker history hello-world:v1
IMAGE          CREATED         CREATED BY                                      SIZE      COMMENT
bf756fb1ae65   13 months ago   /bin/sh -c #(nop)  CMD ["/hello"]               0B
<missing>      13 months ago   /bin/sh -c #(nop) COPY file:7bf12aab75c3867a…   13.3kB
```

## save

`docker save`：保存一个或多个镜像成tar归档文件（默认标准输出）。

**语法**

```
docker save [OPTIONS] IMAGE [IMAGE...]

Options:
  -o, --output string   输出到的文件
```

**实例**

```
docker save -o hello.tar hello-world:v1
ll hello.tar
-rw-------. 1 golang golang 24576 2月  11 19:57 hello.tar
```

## load

`docker load`：导入使用`docker save`命令导出的镜像。

**语法**

```
docker load [OPTIONS]

Options:
  -i, --input string   指定导入的文件，代替标准输入
  -q, --quiet          精简输出信息
```

**实例**

```
$ docker images hello-world
REPOSITORY   TAG       IMAGE ID   CREATED   SIZE
$ docker load -i hello.tar
9c27e219663c: Loading layer [==================================================>]  15.36kB/15.36kB
Loaded image: hello-world:v1
$ docker images hello-world
REPOSITORY    TAG       IMAGE ID       CREATED         SIZE
hello-world   v1        bf756fb1ae65   13 months ago   13.3kB
```

## import

`docker import`：从归档文件中创建镜像。

**语法**

```
docker import [OPTIONS] file|URL|- [REPOSITORY[:TAG]]

Options:
  -c, --change list       应用docker指令创建镜像
  -m, --message string    提交时的说明文字
      --platform string   设置多平台可用
```

**实例**

```
$ docker import hello.tar hello-world:v2
sha256:0243f312226d99ba0cd5e167e894c2910803595a8f81aec270305ae52dca41e6
$ docker images hello-world
REPOSITORY    TAG       IMAGE ID       CREATED         SIZE
hello-world   v2        0243f312226d   7 seconds ago   18.3kB
```

## image

`docker image`：管理镜像

**语法**

```
docker image COMMAND

Commands:
  build       同docker build
  history     同docker history
  import      同docker import
  inspect     展示镜像的详细信息
  load        同docker load
  ls          列举镜像
  prune       删除未使用的镜像
  pull        同docker pull
  push        同docker push
  rm          同docker rmi
  save        同docker save
  tag         同docker tag
```