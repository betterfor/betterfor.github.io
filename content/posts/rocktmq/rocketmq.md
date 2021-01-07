---
title: "docker安装部署Rocketmq"
date: 2021-01-07T16:50:55+08:00
draft: true

tags: ['linux','tool']
categories: ['golang']
comment: true
toc: true
autoCollapseToc: false
---

## RocketMQ

消息队列作为高并发系统的组件之一，能够帮助业务系统解构提高开发效率和系统稳定性。

优势：

- 削峰填谷：解决瞬时写压力导致的消息丢失、系统崩溃等问题
- 系统解耦：处理不同重要程度和不同能力级别系统之间的消息
- 提升性能：当存在一对多调用是，可以发一条消息给消息系统，让消息系统通知相关系统
- 蓄流压测：可以堆积一定的消息量来压测

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2021/01/07/rocketmq.png)



## 安装RocketMQ

[官方地址](https://github.com/apache/rocketmq-docker)

```bash
# git clone https://github.com/apache/rocketmq-docker.git
# cd rocketmq-docker/
# ls
CONTRIBUTING.md  image-build  LICENSE  NOTICE  product  README.md  stage.sh  templates
# cd image-build/
# ls
build-image.sh  Dockerfile-alpine  Dockerfile-centos  scripts  update.sh

```

### 创建RocketMQ镜像

sh build-image.sh RMQ-VERSION BASE-IMAGE

[RMQ-VERSION](https://archive.apache.org/dist/rocketmq/)

BASE-IMAGE支持centos，alpine两种方式

我们使用

sh build-image.sh 4.7.1 alpine

构建时间有点长，需要耐心等待。

当构建完成之后会提示

```bash
Successfully built 128108c2e50d
Successfully tagged apacherocketmq/rocketmq:4.7.1-alpine
```

那么我们就能查询到镜像

```bash
# docker images |grep mq
apacherocketmq/rocketmq  4.7.1-alpine   128108c2e50d     4   9 seconds ago      145MB
```

### 生成配置

```bash
# cd ..
# ls
CONTRIBUTING.md  image-build  LICENSE  NOTICE  product  README.md  stage.sh  templates
# sh stage.sh 4.7.1 (这里的4.7.1对应之前的镜像版本)
Stage version = 4.7.1
mkdir /root/rocketmq/rocketmq-docker/stages/4.7.1
staged templates into folder /root/rocketmq/rocketmq-docker/stages/4.7.1
# ls
CONTRIBUTING.md  image-build  LICENSE  NOTICE  product  README.md  stages  stage.sh  templates
```

生成了stages目录，里面存放配置模板文件

```bash
# cd stages/
# ls
4.7.1
# cd 4.7.1/
# ls
templates
# cd templates/
# ls
data            kubernetes        play-docker-compose.sh  play-docker.sh      play-kubernetes.sh  ssl
docker-compose  play-consumer.sh  play-docker-dledger.sh  play-docker-tls.sh  play-producer.sh
```

#### 1、单机

```bash
./play-docker.sh alpine
```

#### 2、docker-compose

```bash
./play-docker-compose.sh
```

#### 3、kubernetes集群

```bash
./play-kubernetes.sh
```

#### 4、Cluster of Dledger storage(RocketMQ需要4.4.0版本以上)

```bash
./play-docker-dledger.sh
```

#### 5、TLS

```bash
./play-docker-tls.sh
./play-producer.sh
./play-consumer.sh
```



我这里选择的是单机部署，可以看到生成了两个容器

```bash
# docker ps |grep mq
5b557ea1e6be        apacherocketmq/rocketmq:4.7.1-alpine                         "sh mqbroker"            25 seconds ago                                                                                      Up 24 seconds       0.0.0.0:10909->10909/tcp, 9876/tcp, 0.0.0.0:10911-10912->10911-10912/tcp   rmqbroker
8b1318aee5d6        apacherocketmq/rocketmq:4.7.1-alpine                         "sh mqnamesrv"           26 seconds ago                                                                                      Up 25 seconds       10909/tcp, 0.0.0.0:9876->9876/tcp, 10911-10912/tcp                         rmqnamesrv
```

验证RocketMQ启动成功

1、使用命令 `docker ps|grep rmqbroker` 找到RocketMQ broker的容器id

2、使用命令 `docker exec -it 5b557ea1e6be ./mqadmin clusterList -n {nameserver_ip}:9876` 验证RocketMQ broker工作正常

```bash
# docker exec -it 5b557ea1e6be ./mqadmin clusterList -n {nameserver_ip}:9876
RocketMQLog:WARN No appenders could be found for logger (io.netty.util.internal.PlatformDependent0).
RocketMQLog:WARN Please initialize the logger system properly.
#Cluster Name     #Broker Name            #BID  #Addr                  #Version                #InTPS(LOAD)       #OutTPS(LOAD) #PCWait(ms) #Hour #SPACE
DefaultCluster    5b557ea1e6be            0     172.17.0.8:10911       V4_7_1                   0.00(0,0ms)         0.00(0,0ms)          0 447225.46 -1.0000
```

### 升级

```bash
cd image-build
./update.sh
```

## 安装GUI

```bash
# docker pull apacherocketmq/rocketmq-console:2.0.0
# docker run -e "JAVA_OPTS=-Drocketmq.namesrv.addr=192.168.150.70:9876 -Dcom.rocketmq.sendMessageWithVIPChannel=false" -p 6881:8080 -t apacherocketmq/rocketmq-console:2.0.0
```

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2021/01/07/rocket_console.png)

