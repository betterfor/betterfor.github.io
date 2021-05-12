# docker安装部署Rocketmq


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

### golang client使用问题

由于使用的docker服务启动，broker的地址是内网地址，需要将地址修改为外网地址

```bash
# docker ps |grep mq
8abb966542a3        apacherocketmq/rocketmq-console:2.0.0                        "sh -c 'java $JAVA..."   17 hours ago        Up 17 hours         0.0.0.0:6881->8080/tcp                                                     dazzling_tesla
5b557ea1e6be        apacherocketmq/rocketmq:4.7.1-alpine                         "sh mqbroker"            18 hours ago        Up 18 hours         0.0.0.0:10909->10909/tcp, 9876/tcp, 0.0.0.0:10911-10912->10911-10912/tcp   rmqbroker
8b1318aee5d6        apacherocketmq/rocketmq:4.7.1-alpine                         "sh mqnamesrv"           18 hours ago        Up 18 hours         10909/tcp, 0.0.0.0:9876->9876/tcp, 10911-10912/tcp                         rmqnamesrv
# docker exec -it 5b557ea1e6be bash // 进入到容器内部修改配置
# vi ../confbroker.conf
```

![](https://raw.githubusercontent.com/betterfor/cloudImage/master/images/2021/01/08/broker.png)

在文件中添加 `brokerIP1=xxx.xxx.xxx.xxx`

然后重启broker, `docker restart 5b557ea1e6be`

> > > > > ==这里需要去修改启动脚本 ./play-docker.sh 里的start_namesrv_broker() 函数中的docker启动命令，在mybroker后面添加`-c ../conf/broker.conf`== 

```bash
# Start Broker
    docker run -d -v `pwd`/data/broker/logs:/home/rocketmq/logs -v `pwd`/data/broker/store:/home/rocketmq/store --name rmqbroker --link rmqnamesrv:namesrv -e "NAMESRV_ADDR=namesrv:9876" -p 10909:10909 -p 10911:10911 -p 10912:10912 apacherocketmq/rocketmq:4.7.1${TAG_SUFFIX} sh mqbroker -c ../conf/broker.conf
```

这样查看cluster会发现Address变成外网地址。



### client-go Topic

```go
package main

import (
	"context"
	"fmt"
	"github.com/apache/rocketmq-client-go/v2/admin"
	"github.com/apache/rocketmq-client-go/v2/primitive"
)

func main() {
	topic := "Develop"
	nameSrvAddr := []string{"192.168.150.70:9876"}
	brokerAddr := "192.168.150.70:10911"

	testAdmin, err := admin.NewAdmin(admin.WithResolver(primitive.NewPassthroughResolver(nameSrvAddr)))
	if err != nil {
		panic(err)
	}

	// 创建topic
	err = testAdmin.CreateTopic(
		context.Background(),
		admin.WithTopicCreate(topic),
		admin.WithBrokerAddrCreate(brokerAddr))
	if err != nil {
		fmt.Println("Create topic error:", err)
	}

	// 删除topic
	err = testAdmin.DeleteTopic(
		context.Background(),
		admin.WithTopicDelete(topic),
		//admin.WithBrokerAddrDelete(brokerAddr), 
		//admin.WithNameSrvAddr(nameSrvAddr),
	)

	err = testAdmin.Close()
	if err != nil {
		fmt.Println("Shutdown admin error:", err)
	}
}

```

### client-go 生产者

```go
package main

import (
	"context"
	"fmt"
	"github.com/apache/rocketmq-client-go/v2"
	"github.com/apache/rocketmq-client-go/v2/primitive"
	"github.com/apache/rocketmq-client-go/v2/producer"
	"strconv"
)

func main() {
	addr,err := primitive.NewNamesrvAddr("192.168.150.70:9876")
	if err != nil {
		panic(err)
	}
	topic := "Develop"
	p,err := rocketmq.NewProducer(
		producer.WithGroupName("my_service"),
		producer.WithNameServer(addr),
		producer.WithCreateTopicKey(topic),
		producer.WithRetry(1))
	if err != nil {
		panic(err)
	}

	err = p.Start()
	if err != nil {
		panic(err)
	}

	// 发送异步消息
	res,err := p.SendSync(context.Background(),primitive.NewMessage(topic,[]byte("send sync message")))
	if err != nil {
		fmt.Printf("send sync message error:%s\n",err)
	} else {
		fmt.Printf("send sync message success. result=%s\n",res.String())
	}

	// 发送消息后回调
	err = p.SendAsync(context.Background(), func(ctx context.Context, result *primitive.SendResult, err error) {
		if err != nil {
			fmt.Printf("receive message error:%v\n",err)
		} else {
			fmt.Printf("send message success. result=%s\n",result.String())
		}
	},primitive.NewMessage(topic,[]byte("send async message")))
	if err != nil {
		fmt.Printf("send async message error:%s\n",err)
	}

	// 批量发送消息
	var msgs []*primitive.Message
	for i := 0; i < 5; i++ {
		msgs = append(msgs, primitive.NewMessage(topic,[]byte("batch send message. num:"+strconv.Itoa(i))))
	}
	res,err = p.SendSync(context.Background(),msgs...)
	if err != nil {
		fmt.Printf("batch send sync message error:%s\n",err)
	} else {
		fmt.Printf("batch send sync message success. result=%s\n",res.String())
	}

	// 发送延迟消息
	msg := primitive.NewMessage(topic,[]byte("delay send message"))
	msg.WithDelayTimeLevel(3)
	res,err = p.SendSync(context.Background(),msg)
	if err != nil {
		fmt.Printf("delay send sync message error:%s\n",err)
	} else {
		fmt.Printf("delay send sync message success. result=%s\n",res.String())
	}

	// 发送带有tag的消息
	msg1 := primitive.NewMessage(topic,[]byte("send tag message"))
	msg1.WithTag("tagA")
	res,err = p.SendSync(context.Background(),msg1)
	if err != nil {
		fmt.Printf("send tag sync message error:%s\n",err)
	} else {
		fmt.Printf("send tag sync message success. result=%s\n",res.String())
	}

	err = p.Shutdown()
	if err != nil {
		panic(err)
	}
}
```

### client-go 消费者

```go
// 在v2.1.0-rc5.0不支持，会在下一个版本中支持
func PullConsumer() {
	topic := "Develop"

	// 消费者主动拉取消息
	// not
	c1,err := rocketmq.NewPullConsumer(
		consumer.WithGroupName("my_service"),
		consumer.WithNsResolver(primitive.NewPassthroughResolver([]string{"192.168.150.70:9876"})))
	if err != nil {
		panic(err)
	}
	err = c1.Start()
	if err != nil {
		fmt.Println(err)
		os.Exit(-1)
	}
	queue := primitive.MessageQueue{
		Topic:      topic,
		BrokerName: "broker-a", // 使用broker的名称
		QueueId:    0,
	}

	err = c1.Shutdown()
	if err != nil {
		fmt.Println("Shutdown Pull Consumer error: ",err)
	}

	offset := int64(0)
	for  {
		resp,err := c1.PullFrom(context.Background(),queue,offset,10)
		if err != nil {
			if err == rocketmq.ErrRequestTimeout {
				fmt.Printf("timeout\n")
				time.Sleep(time.Second)
				continue
			}
			fmt.Printf("unexpected error: %v\n",err)
			return
		}
		if resp.Status == primitive.PullFound {
			fmt.Printf("pull message success. nextOffset: %d\n",resp.NextBeginOffset)
			for _, ext := range resp.GetMessageExts() {
				fmt.Printf("pull msg: %s\n",ext)
			}
		}
		offset = resp.NextBeginOffset
	}
}

func PushConsumer() {
	topic := "Develop"

	// 消息主动推送给消费者
	c2,err := rocketmq.NewPushConsumer(
		consumer.WithGroupName("my_service"),
		consumer.WithNsResolver(primitive.NewPassthroughResolver([]string{"192.168.150.70:9876"})),
        consumer.WithConsumeFromWhere(consumer.ConsumeFromFirstOffset), // 选择消费时间(首次/当前/根据时间)
        consumer.WithConsumerModel(consumer.BroadCasting)) // 消费模式(集群消费:消费完其他人不能再读取/广播消费：所有人都能读)
	if err != nil {
		panic(err)
	}

	err = c2.Subscribe(
		topic,consumer.MessageSelector{
		Type: consumer.TAG,
		Expression: "*", // 可以 TagA || TagB
		},
	func(ctx context.Context, msgs ...*primitive.MessageExt) (consumer.ConsumeResult, error) {
		orderlyCtx,_ := primitive.GetOrderlyCtx(ctx)
		fmt.Printf("orderly context: %v\n",orderlyCtx)
		for i := range msgs {
			fmt.Printf("Subscribe callback: %v\n",msgs[i])
		}
		return consumer.ConsumeSuccess,nil
	})
	if err != nil {
		fmt.Printf("Subscribe error:%s\n",err)
	}

	err = c2.Start()
	if err != nil {
		fmt.Println(err)
		os.Exit(-1)
	}
	time.Sleep(time.Minute)
	err = c2.Shutdown()
	if err != nil {
		fmt.Println("Shutdown Consumer error: ",err)
	}
}
```


