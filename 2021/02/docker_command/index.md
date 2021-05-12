# Docker命令大全


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


