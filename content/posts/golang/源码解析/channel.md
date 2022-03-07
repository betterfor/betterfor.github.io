---
title: "channel源码解析"
date: 2022-03-07T11:16:04+08:00
draft: false

tags: ['channel']
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: false
---

golang有一个很重要的特性就是`channel`，经常配合`goroutine`一起使用。

## 一、基本用法

- 初始化

```go
ch := make(chan bool)
```

- 发送数据

```go
ch <- x
```

- 接受数据

```go
x := <- ch
x,ok := <- ch
```

当然，其中也涉及到有缓冲和无缓冲的情况，为什么会造成这种情况，我们会在下面解释。

## 二、数据结构

```go
type hchan struct {
	qcount   uint           // 队列中数据的个数
	dataqsiz uint           // 队列容量
	buf      unsafe.Pointer // 存放在环形数组的数据
	elemsize uint16         // channel中数据类型大小
	closed   uint32         // channel是否关闭
	elemtype *_type         // 元素类型
	sendx    uint           // send的数组索引
	recvx    uint           // receive的数组索引
	recvq    waitq          // <-ch 阻塞在chan上的队列 list of recv waiters
	sendq    waitq          // ch<- 阻塞在chan上的队列 list of send waiters
	lock mutex
}
```

`channel`的数据结构不太复杂，就是一个环形队列，里面保存了长度`qcount`，容量`dataqsiz`，数据`buf`，以及前后索引`sendx`，`recvx`。

`closed`用来标识`channel`的状态，0表示未关闭，非0表示已关闭，如果关闭，那么就不能发送数据。

## 三、初始化

在内部有两个`make`函数，一个是`makechan64`，一个是`makechan`，其实`makechan64`本质上还是调用的`makechan`。

### 1、长度判断

```go
elem := t.elem
if elem.size >= 1<<16 {
	throw("makechan: invalid channel element type")
}
if hchanSize%maxAlign != 0 || elem.align > maxAlign {
	throw("makechan: bad alignment")
}

mem, overflow := math.MulUintptr(elem.size, uintptr(size))
if overflow || mem > maxAlloc-hchanSize || size < 0 {
	panic(plainError("makechan: size out of range"))
}
```

初始化的时候可以传入长度`size`，然后根据你初始化数据的类型大小`elem.size`计算是否有可用空间。

### 2、分配内存

```go
var c *hchan
switch {
case mem == 0:
	c = (*hchan)(mallocgc(hchanSize, nil, true))
	c.buf = c.raceaddr()
case elem.ptrdata == 0:
	c = (*hchan)(mallocgc(hchanSize+mem, nil, true))
	c.buf = add(unsafe.Pointer(c), hchanSize)
default:
	c = new(hchan)
	c.buf = mallocgc(mem, elem, true)
}
```

- 如果`size`为0，只分配`hchanSize`的大小，如果是64位就是80，如果是32位就是40
- 如果数据类型不是指针，分配一块连续内存`hchanSize`+`mem`
- 如果数据类型是指针，`hchan`和`buf`单独分配

此时，将结构体剩余字段赋值。

```go
c.elemsize = uint16(elem.size)
c.elemtype = elem
c.dataqsiz = uint(size)
```

## 四、send

就是`ch <- x`

调用的函数签名是`chansend(c *hchan, ep unsafe.Pointer, block bool, callerpc uintptr) bool`

### 1、空chan判断

首先判断channel是否初始化

```go
if c == nil {
	if !block {
		return false
	}
	gopark(nil, nil, waitReasonChanSendNilChan, traceEvGoStop, 2)
	throw("unreachable")
}
```

其次判断channel是否关闭

```go
if !block && c.closed == 0 && ((c.dataqsiz == 0 && c.recvq.first == nil) ||
	(c.dataqsiz > 0 && c.qcount == c.dataqsiz)) {
	return false
}
```

这段判断逻辑还是比较复杂的。

这个是`fast path`，向没有阻塞的管道判断发送失败，这样就可以不用获取锁进行判断了。

如果是非阻塞，管道没有关闭的情况下，没有缓冲区或缓冲区已经满了，返回false。

由于这里是并发执行的，可能会在判断完`c.closed==0`之后，关闭`channel`，那么这里会出现这两种情况：

1、`channel`没有关闭，没有缓冲区或缓冲区已经满了，返回false

2、`channel`已经关闭，`close`会加锁将`recvq`和`sendq`全部出队列，返回false

所以这里的判断是十分严谨的。

### 2、加锁

```go
lock(&c.lock)

if c.closed != 0 {
	unlock(&c.lock)
	panic(plainError("send on closed channel"))
}
```

### 3、取出接受者

```go
if sg := c.recvq.dequeue(); sg != nil {
	send(c, sg, ep, func() { unlock(&c.lock) }, 3)
	return true
}
```

找到一个等待的接受者，直接发送

### 4、是否有缓冲

如果没有找到有等待的接受者，那么就看`channel`是否是有缓冲的。

```go
if c.qcount < c.dataqsiz {
	// Space is available in the channel buffer. Enqueue the element to send.
	qp := chanbuf(c, c.sendx)
	typedmemmove(c.elemtype, qp, ep)
	c.sendx++
	if c.sendx == c.dataqsiz {
		c.sendx = 0
	}
	c.qcount++
	unlock(&c.lock)
	return true
}
```

可以看到环形队列的判断

如果到这里，前面的步骤都没有发送成功，表示没有接受者等待，也没有缓冲区，那么就需要挂起goroutine等待接受者了。

```go
if !block {
	unlock(&c.lock)
	return false
}
```

### 5、阻塞goroutine

```go
gp := getg()
mysg := acquireSudog()
mysg.releasetime = 0
if t0 != 0 {
	mysg.releasetime = -1
}

mysg.elem = ep
mysg.waitlink = nil
mysg.g = gp
mysg.isSelect = false
mysg.c = c
gp.waiting = mysg
gp.param = nil
c.sendq.enqueue(mysg)
atomic.Store8(&gp.parkingOnChan, 1)
gopark(chanparkcommit, unsafe.Pointer(&c.lock), waitReasonChanSend, traceEvGoBlockSend, 2)

KeepAlive(ep)
```

添加发送者到发送队列，调用`gopark`阻塞

### 6、发送完成

```go
if mysg != gp.waiting {
	throw("G waiting list is corrupted")
}
gp.waiting = nil
gp.activeStackChans = false
if gp.param == nil {
	if c.closed == 0 {
		throw("chansend: spurious wakeup")
	}
	panic(plainError("send on closed channel"))
}
gp.param = nil
if mysg.releasetime > 0 {
	blockevent(mysg.releasetime-t0, 2)
}
mysg.c = nil
releaseSudog(mysg)
```

goroutine被唤醒后，表示发送完成，清理现场

## 五、recv

```go
func chanrecv1(c *hchan, elem unsafe.Pointer) {
	chanrecv(c, elem, true)
}
```

对应的是`x <- ch`

```go
func chanrecv2(c *hchan, elem unsafe.Pointer) (received bool) {
	_, received = chanrecv(c, elem, true)
	return
}
```

对应的是`x,ok :=<- ch `

### 1、空channel判断

```go
if c == nil {
	if !block {
		return
	}
	gopark(nil, nil, waitReasonChanReceiveNilChan, traceEvGoStop, 2)
	throw("unreachable")
}
```

同样这里也有个`fast path`

```go
if !block && (c.dataqsiz == 0 && c.sendq.first == nil ||
	c.dataqsiz > 0 && atomic.Loaduint(&c.qcount) == 0) &&
	atomic.Load(&c.closed) == 0 {
	return
}
```

这里把是否关闭放在了最后进行判断，与发送不一样，这是因为接受的时候会走default分支

```go
c := make(chan int, 1)
c <- 1
go func() {
    select {
    case <- c:
        println("receive from c")
    default:
        println("c is not ready")
    }
}
close(c)
```

这段代码应该不执行default分支。

可能会出现如下情况：

- select发生在close之前，从c中取出1
- select发送在close之后，但在<-c 之前，取出1
- select发送在<-c之后，取出0，received=false，但不会执行default

如果这里我们把`c.closed`的判断放在前面的话，会出现以下情况：

- 通道未关闭，不存在可接受数据，没有发送者等待，返回(false, false)
- 通道已关闭，不存在可接受数据，没有发送者等待，应该要返回(ture, false)，这里返回了(false, false)

这里，`selected`应该为`true`，所以把`c.closed`放在最后判断可以避免这种情况。

### 2、通道关闭

```go
lock(&c.lock)

if c.closed != 0 && c.qcount == 0 {
	unlock(&c.lock)
	if ep != nil {
		typedmemclr(c.elemtype, ep)
	}
	return true, false
}
```

 如果通道已经关闭并且没有数据可以读取，返回(true,false)

### 3、取出发送者

```go
if sg := c.sendq.dequeue(); sg != nil {
	recv(c, sg, ep, func() { unlock(&c.lock) }, 3)
	return true, true
}
```

找到一个发送者，接受数据

### 4、是否有缓冲

```go
if c.qcount > 0 {
	qp := chanbuf(c, c.recvx)
	if ep != nil {
		typedmemmove(c.elemtype, ep, qp)
	}
	typedmemclr(c.elemtype, qp)
	c.recvx++
	if c.recvx == c.dataqsiz {
		c.recvx = 0
	}
	c.qcount--
	unlock(&c.lock)
	return true, true
}
```

### 5、阻塞goroutine

```go
gp := getg()
mysg := acquireSudog()
mysg.releasetime = 0
if t0 != 0 {
	mysg.releasetime = -1
}

mysg.elem = ep
mysg.waitlink = nil
gp.waiting = mysg
mysg.g = gp
mysg.isSelect = false
mysg.c = c
gp.param = nil
c.recvq.enqueue(mysg)
atomic.Store8(&gp.parkingOnChan, 1)
gopark(chanparkcommit, unsafe.Pointer(&c.lock), waitReasonChanReceive, traceEvGoBlockRecv, 2)
```

### 6、接受完成

```go
if mysg != gp.waiting {
	throw("G waiting list is corrupted")
}
gp.waiting = nil
gp.activeStackChans = false
if mysg.releasetime > 0 {
	blockevent(mysg.releasetime-t0, 2)
}
closed := gp.param == nil
gp.param = nil
mysg.c = nil
releaseSudog(mysg)
```

## 六、关闭channel

这部分比较简单，就是加锁，设置标识位`c.closed`，然后唤醒所有的接受者和发送者，接受和发送数据，最后释放锁。

## 七、总结

1、`channel`底层就是一个环形队列

2、在有接受者或发送者的情况下，在`select`中不会走`default`分支

3、初始化的缓冲就是对应的是否阻塞`block`