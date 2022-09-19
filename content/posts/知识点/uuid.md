---
title: "生成uuid的几种方式"
date: 2021-02-08T14:16:15+08:00
draft: false

tags: ['uuid','snowflake']
categories: ["note"]
comment: true
toc: true
autoCollapseToc: false
---

## 背景

在复杂的分布式系统中，往往需要对大量的数据和消息进行唯一标识。数据日益增长，对数据库需要进行切分，而水平切分数据库需要一个唯一ID来标识一条数据或消息，数据库的自增ID显然不能满足需求。那么对于[分布式全局ID](https://tech.meituan.com/2017/04/21/mt-leaf.html)有什么要求呢？

- 全局唯一性：不能出现重复的ID号。
- 趋势递增：在MySQL InnoDB引擎中使用的是聚集索引，由于多数RDBMS使用B-tree的数据结构来存储索引数据，在主键的选择上面我们应该尽量使用有序的主键保证写入性能。
- 单调递增：保证下一个ID一定大于上一个ID，例如事务版本号、IM增量消息、排序等特殊需求。
- 信息安全：如果ID是连续的，会出现安全问题，在一些场景中，会需要ID无规则，不规则。

## UUID

UUID(Universally Unique Identifier)是一个128位标识符，在其规范的文本表示中，UUID 的 16 个 8 位字节表示为 32 个十六进制（基数16）数字，显示在由连字符分隔 '-' 的五个组中，"8-4-4-4-12" 总共 36 个字符（32 个字母数字字符和 4 个连字符）。例如：`123e4567-e89b-12d3-a456-426655440000`。

- 优点：性能高，本地生成，没有网络消耗

- 缺点：

  1、不易存储：UUID太长，很多场景不适用。

  2、信息不安全：基于MAC地址生成的UUID算法可能造成MAC地址泄露。

  3、没有排序，无法保证递增趋势。

  4、不易读，存储空间大。

  go两种生成UUID的第三方包：

  [github.com/google/uuid](https://github.com/google/uuid)

  [github.com/satori/go.uuid](https://github.com/satori/go.uuid)

## Snowflake

[snowflake](https://github.com/twitter-archive/snowflake/blob/snowflake-2010/src/main/scala/com/twitter/service/snowflake/IdWorker.scala)是Twitter开源的分布式ID生成算法，结果是一个long型的ID。其核心思想是：使用41bit作为毫秒数，10bit作为机器的ID（5个bit是数据中心，5个bit的机器ID），12bit作为毫秒内的流水号（意味着每个节点在每毫秒可以产生 4096 个 ID），最后还有一个符号位，永远是0。

1、实现原理：

![snowflake](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/08/snowflake.png)

1位最高位：符号位不使用，0表示正数，1表示负数。

41位时间戳：`1<<41` = `1000*3600*24*365` = 69 年。

10位工作机器id：如果我们对IDC划分有需求可以用5位给IDC，5位给工作机器，这样就可以表示32个IDC，每个IDC下有32台机器。

12位自增ID：可以表示2^12^个ID。

理论上snowflake方案的QPS约为409.3w/s，这种分配方式可以保证在任何一个IDC的任何一台机器在任意毫秒内生成的ID都是不同的。

**优点：**

- 毫秒数在高位，自增序列在低位，整个ID都是趋势递增的。
- 不依赖数据库等第三方系统，以服务的方式部署，稳定性更高，生成ID的性能也是非常高的。
- 可以根据自身业务特性分配bit位，非常灵活。

**缺点：**

- 强依赖机器时钟，如果机器上时钟回拨，会导致发号重复或者服务会处于不可用状态。

代码实现：

```go
package main

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"time"
)

//global var
var sequence int = 0
var lastTime int = -1
//every segment bit
var workerIdBits = 5
var datacenterIdBits = 5
var sequenceBits = 12
//every segment max number
var maxWorkerId int = -1 ^ (-1 << workerIdBits)
var maxDatacenterId int = -1 ^ (-1 << datacenterIdBits)
var maxSequence int = -1 ^ (-1 << sequenceBits)
//bit operation shift
var workerIdShift = sequenceBits
var datacenterShift = workerIdBits + sequenceBits
var timestampShift = datacenterIdBits + workerIdBits + sequenceBits

type Snowflake struct {
	datacenterId int
	workerId     int
	epoch        int
	mt           *sync.Mutex
}

func NewSnowflake(datacenterId int, workerId int, epoch int) (*Snowflake, error) {
	if datacenterId > maxDatacenterId || datacenterId < 0 {
		return nil, errors.New(fmt.Sprintf("datacenterId cant be greater than %d or less than 0", maxDatacenterId))
	}
	if workerId > maxWorkerId || workerId < 0 {
		return nil, errors.New(fmt.Sprintf("workerId cant be greater than %d or less than 0", maxWorkerId))
	}
	if epoch > getCurrentTime() {
		return nil, errors.New(fmt.Sprintf("epoch time cant be after now"))
	}
	sf := Snowflake{datacenterId, workerId, epoch, new(sync.Mutex)}
	return &sf, nil
}

func (sf *Snowflake) getUniqueId() int {
	sf.mt.Lock()
	defer sf.mt.Unlock()
	//get current time
	currentTime := getCurrentTime()
	//compute sequence
	if currentTime < lastTime { //occur clock back
		//panic or wait,wait is not the best way.can be optimized.
		currentTime = waitUntilNextTime(lastTime)
		sequence = 0
	} else if currentTime == lastTime { //at the same time(micro-second)
		sequence = (sequence + 1) & maxSequence
		if sequence == 0 { //overflow max num,wait next time
			currentTime = waitUntilNextTime(lastTime)
		}
	} else if currentTime > lastTime { //next time
		sequence = 0
		lastTime = currentTime
	}
	//generate id
	return (currentTime-sf.epoch)<<timestampShift | sf.datacenterId<<datacenterShift |
		sf.workerId<<workerIdShift | sequence
}

func waitUntilNextTime(lasttime int) int {
	currentTime := getCurrentTime()
	for currentTime <= lasttime {
		time.Sleep(1 * time.Second / 1000) //sleep micro second
		currentTime = getCurrentTime()
	}
	return currentTime
}

func getCurrentTime() int {
	return int(time.Now().UnixNano() / 1e6) //micro second
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())
	datacenterId := 0
	workerId := 0
	epoch := 1596850974657
	s, err := NewSnowflake(datacenterId, workerId, epoch)
	if err != nil {
		panic(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 1000000; i++ {
		wg.Add(1)
		go func() {
			fmt.Println(s.getUniqueId())
			wg.Done()
		}()
	}
	wg.Wait()
}
```

## 数据库ID

利用数据库字段设置auto_increment_increment和auto_increment_offset来保证ID自增，每次业务使用一下SQL读写MySQL得到ID。

```mysql
begin;
REPLACE into Tickets (id) values (null);
select LAST_INSERT_ID();
commit;
```

![mysql_id](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/08/mysql_id.png)

- 优点：简单，利用数据库的功能实现，成本小；id单调递增。
- 缺点：强依赖数据库，当数据库不可用时，是致命问题；ID发号性能瓶颈限制在单台MySQL的读写性能上。

对于MySQL性能问题，可用如下方法解决：

在分布式系统中部署多台机器，每台机器设置不同的初始值，且步长相等。例如设置步长为2，`TicketServer1`的初始值为1` (1,3,5,7...)`, `TicketServer1`的初始值为2`(2,4,6,8...)`。

[主键生成策略](https://code.flickr.net/2010/02/08/ticket-servers-distributed-unique-primary-keys-on-the-cheap/)

缺点：

- 水平扩展比较困难，事先定好步长和机器后，如果后续新增机器，不容易扩容。
- 数据库压力还是大，只能靠堆机器来提高性能。

## MongoDB ID

[MongoDB官方文档 ObjectID](https://docs.mongodb.com/manual/reference/method/ObjectId/#description)和snowflake算法类似，它设计成轻量型的，不同的机器都能用全局唯一的同种方法便利生成。通过 `时间戳+机器+pid+自增id` 共12个字节，通过 `4+3+2+3` 的方式生成24位的十六进制字符。

## Zookeeper ID

zookeeper主要通过其znode数据版本来生成序列号，可以生成32位和64位的数据版本号，客户端可以使用这个版本号来作为唯一的序列号。

很少会使用zookeeper来生成唯一ID。主要是由于需要依赖zookeeper，并且是多步调用API，如果在竞争较大的情况下，需要考虑使用分布式锁。因此，性能在高并发的分布式环境下，也不甚理想。