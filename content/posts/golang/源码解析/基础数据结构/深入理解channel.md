---
title: "深入理解channel"
date: 2021-07-15T15:00:10+08:00
draft: false

tags: ['源码解析','channel']
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: false
---

`channel`设计的基本思想是：

不要通过共享内存来通信，而是要通过通信来实现共享内存。

**Do not communicate by sharing memory; instead, share memory by communicating**.

`channel`在设计上本质就是一个有锁的环形队列，包括发送方队列、接收方队列、互斥锁等结构。

下面就开始源码剖析这个有锁的环形队列是如何设计的。

## 数据结构

在`runtime/chan.go`中可以看到`hchan`的结构如下：

```go
// 64位占用80,32位占用44
type hchan struct {
	qcount   uint           // 队列中数据的个数
	dataqsiz uint           // 队列容量
	buf      unsafe.Pointer // 存放在环形数组的数据
	elemsize uint16         // channel中数据类型大小
	closed   uint32         // channel是否关闭，0表示未关闭，非0表示已关闭
	elemtype *_type         // 元素类型
	sendx    uint           // send的数组索引
	recvx    uint           // receive的数组索引
	recvq    waitq          // <-ch 阻塞在chan上的队列 list of recv waiters
	sendq    waitq          // ch<- 阻塞在chan上的队列 list of send waiters

	// lock protects all fields in hchan, as well as several
	// fields in sudogs blocked on this channel.
	// 不要在持有锁（特别是G没有准备好的时候）改变另一个G的状态，因为这可能导致栈收缩
	// Do not change another G's status while holding this lock
	// (in particular, do not ready a G), as this can deadlock
	// with stack shrinking.
	lock mutex
}
```

- `buf`是指向底层的循环数组，`dataqsiz`就是这个循环数组的长度，`qcount`就是当前循环数据中的元素数量。
- `elemsize`和`elemtype`就是创建`channel`时设置的元素类型和大小
- `sendq`和`recvq`是一个双向链表，分别表示被阻塞的`goroutine`链表，这些`goroutine`由于尝试读取/发送数据而阻塞。

基于此，如下图

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/15/3854964269.png)

## channel的创建

通常我们使用`make`进行创建，`make`在经过编译器编译后的两种方法`runtime.makechan`和`runtime.makechan64`。

```go
//go:linkname reflect_makechan reflect.makechan
func reflect_makechan(t *chantype, size int) *hchan {
	return makechan(t, size)
}

func makechan64(t *chantype, size int64) *hchan {
	if int64(int(size)) != size {
		panic(plainError("makechan: size out of range"))
	}

	return makechan(t, int(size))
}
```

`makechan64`实际上也是调用`makechan`方法，只不过是多了一个数值溢出的校验。大多数情况还是使用`makechan`。

```go
// 初始化chan， make(chan int,4)
func makechan(t *chantype, size int) *hchan {
	elem := t.elem

	// compiler checks this but be safe.
	// 对发送的元素进行限制 1<<16
	if elem.size >= 1<<16 {
		throw("makechan: invalid channel element type")
	}
	if hchanSize%maxAlign != 0 || elem.align > maxAlign {
		throw("makechan: bad alignment")
	}

	// 计算 类型长度*容量， 如果溢出或超过可分配内存，报错
	mem, overflow := math.MulUintptr(elem.size, uintptr(size))
	if overflow || mem > maxAlloc-hchanSize || size < 0 {
		panic(plainError("makechan: size out of range"))
	}

	// Hchan does not contain pointers interesting for GC when elements stored in buf do not contain pointers.
	// buf points into the same allocation, elemtype is persistent.
	// SudoG's are referenced from their owning thread so they can't be collected.
	// TODO(dvyukov,rlh): Rethink when collector can move allocated objects.
	var c *hchan
	switch {
	case mem == 0:
		// 缓冲区大小为0，只分配sizeof(hchan)大小的内存
		c = (*hchan)(mallocgc(hchanSize, nil, true))
		// Race detector uses this location for synchronization.
		c.buf = c.raceaddr()
	case elem.ptrdata == 0:
		// 数据类型不是指针，分配一块连续内存容纳hchanSize和缓冲区对象
		c = (*hchan)(mallocgc(hchanSize+mem, nil, true))
		c.buf = add(unsafe.Pointer(c), hchanSize)
	default:
		// 数据类型包含指针，hchan和buf单独分配.
		c = new(hchan)
		c.buf = mallocgc(mem, elem, true)
	}

	// channel元素大小，如果是int，就是8字节
	c.elemsize = uint16(elem.size)
	// 元素类型
	c.elemtype = elem
	// 元素buffer数组的大小，比如make(chan int,2)，那么size=2
	c.dataqsiz = uint(size)

	/*
		初始化核心字段：
		1、buf：指明buffer地址
		2、elemsize：指明元素大小
		3、elemtype：指明元素类型
		4、dataqsiz：指明数组大小
	*/

	if debugChan {
		print("makechan: chan=", c, "; elemsize=", elem.size, "; dataqsiz=", size, "\n")
	}
	return c
}
```

这里主要是一些内存分配的操作。

如果创建的`channel`是无缓冲的，或创建的有缓冲的`channel`中存储的数据类型不是指针类型，就会调用`mallocgc`分配一段连续的内存。

如果创建的`channel`中存储的类型存在指针引用，就会连同`hchan`和底层数组同时分配一段连续的内存空间。

## 入队

channel发送数据部分的代码是`runtime.chansend1`

```go
func chansend1(c *hchan, elem unsafe.Pointer) {
	chansend(c, elem, true, getcallerpc())
}
```

### 前置检查

```go
// 如果chan是空的，对于非阻塞发送，直接返回false。对于阻塞的通道，将goroutine挂起，并且永远不返回
	// 也就是不要向一个nil的chan发送数据
	if c == nil {
		if !block {
			return false
		}
		gopark(nil, nil, waitReasonChanSendNilChan, traceEvGoStop, 2)
		throw("unreachable")
	}

	if debugChan {
		print("chansend: chan=", c, "\n")
	}

	if raceenabled {
		racereadpc(c.raceaddr(), callerpc, funcPC(chansend))
	}

	// 非阻塞情况下，如果通道没有关闭，而且没有接受者，缓冲区已经满了或没有缓冲区（即不可以发送数据），返回false
	// 因为这里是允许并发执行的，所以要仔细分析一下
	// 判断完closed之后，通道可能在这一瞬间从未关闭变成关闭状态（closed不会从非0变为0，但可能从0变成非0，也就是通道可能被关闭）
	// 那么这里会有两种情况：
	// 1、通道没有关闭，而且已经满了，那么这段逻辑运行正确，应该返回false
	// 2、通道已经关闭，而关闭的时候（加锁操作）是将recvq和sendq全部出队列，所以也是返回false
	if !block && c.closed == 0 && ((c.dataqsiz == 0 && c.recvq.first == nil) ||
		(c.dataqsiz > 0 && c.qcount == c.dataqsiz)) {
		return false
	}

	var t0 int64
	if blockprofilerate > 0 {
		t0 = cputicks()
	}
```

这里主要的检查就是判断当前`channel`是否为nil，往一个nil的`channel`中发送数据时，会调用`gopark`函数将当前执行的`goroutine`从`running`状态转入`waiting`状态，这会表现出`panic`事件。

### 加锁/异常检查

```go
// 对chan加锁
lock(&c.lock)

// 如果chan关闭，panic
if c.closed != 0 {
	unlock(&c.lock)
	panic(plainError("send on closed channel"))
}
```

前置校验通过后，对`channel`加锁，防止多个协程同时操作并发修改数据。如果`channel`已经关闭，那么发送数据会`panic`。

### channel直接发送数据

```go
// 场景一：从recvq中取出一个接受者，如果接受者存在，则向接受者发送数据
	if sg := c.recvq.dequeue(); sg != nil {
		// Found a waiting receiver. We pass the value we want to send
		// directly to the receiver, bypassing the channel buffer (if any).
		send(c, sg, ep, func() { unlock(&c.lock) }, 3)
		return true
	}
```

这里主要调用了`send`方法

```go
// send函数将ep作为参数传送给接收方sg，然后使用goready将其唤醒。
func send(c *hchan, sg *sudog, ep unsafe.Pointer, unlockf func(), skip int) {
	// sg.elem如果非空，则将ep的内容直接拷贝到elem指向的地址
	// elem是接收到的值存放的位置
	if sg.elem != nil {
		// 调用sendDirect进行内存拷贝，从发送者拷贝到接受者
		sendDirect(c.elemtype, sg, ep)
		sg.elem = nil
	}
	gp := sg.g
	unlockf()
	gp.param = unsafe.Pointer(sg)
	if sg.releasetime != 0 {
		sg.releasetime = cputicks()
	}
	// 唤醒接受的goroutine
	goready(gp, skip+1)
}
```

然后，我们再看看`sendDirect`方法

```go
func sendDirect(t *_type, sg *sudog, src unsafe.Pointer) {
	// src is on our stack, dst is a slot on another stack.

	// Once we read sg.elem out of sg, it will no longer
	// be updated if the destination's stack gets copied (shrunk).
	// So make sure that no preemption points can happen between read & use.
	dst := sg.elem
	typeBitsBulkBarrier(t, uintptr(dst), uintptr(src), t.size)
	// No need for cgo write barrier checks because dst is always
	// Go memory.
	memmove(dst, src, t.size)
}
```

这里直接调用`memmove`方法进行内存拷贝，这里是从一个`goroutine`直接写入另一个`goroutine`栈的操作，减少了一次内存`copy`，不用先拷贝到`channel`的`buf`，直接由发送者到接收者。

### channel发送到数据缓冲区

```go
// 场景二：如果缓冲区还有多余的空间，那么将数据写入缓冲区。写入缓冲区后，将发送位置后移一位，将qcount+1
	if c.qcount < c.dataqsiz {
		// Space is available in the channel buffer. Enqueue the element to send.
		qp := chanbuf(c, c.sendx)
		// typedmemmove 将ep的内容复制到qp上
		typedmemmove(c.elemtype, qp, ep)
		// 递增索引
		c.sendx++
		// 回环空间
		if c.sendx == c.dataqsiz {
			c.sendx = 0
		}
		// 递增元素个数
		c.qcount++
		unlock(&c.lock)
		return true
	}
```

这里的几步还是比较好理解的：

- 如果当前缓冲区还有可用空间，则调用`chanbuf`方法获取底层缓冲数组`sendx`索引元素指针值
- 调用`typedmemmove`方法将发送的值拷贝到缓冲区中
- 数据拷贝成功，`sendx`++，指向下一个待发送元素再循环数组中的位置。如果下一个索引位置正好是循环队列的长度，那么把索引置0。
- 队列元素长度自增，至此发送数据完成，释放锁

### channel发送数据无可用缓冲区

缓冲区满了之后，有两种方式可以选择，一种是直接返回，一种是阻塞等待。

```go
// 如果是非阻塞的，那么就直接解锁返回了
if !block {
	unlock(&c.lock)
	return false
}
```

下面是阻塞等待的代码

```go
// 代码走到这里，说明都是因为条件不满足，要阻塞当前 goroutine，所以做的事情本质上就是保留好通知路径，等待条件满足，会在这个地方唤醒；
	// 获取当前goroutine的sudog，然后入channel的send队列
	// Block on the channel. Some receiver will complete our operation for us.
	gp := getg()
	mysg := acquireSudog()
	mysg.releasetime = 0
	if t0 != 0 {
		mysg.releasetime = -1
	}
	// No stack splits between assigning elem and enqueuing mysg
	// on gp.waiting where copystack can find it.
	mysg.elem = ep
	mysg.waitlink = nil
	mysg.g = gp
	mysg.isSelect = false
	mysg.c = c
	gp.waiting = mysg
	gp.param = nil
	// 把 goroutine 相关的线索结构入队，等待条件满足的唤醒；
	c.sendq.enqueue(mysg)

	// Signal to anyone trying to shrink our stack that we're about
	// to park on a channel. The window between when this G's status
	// changes and when we set gp.activeStackChans is not safe for
	// stack shrinking.
	atomic.Store8(&gp.parkingOnChan, 1)
	gopark(chanparkcommit, unsafe.Pointer(&c.lock), waitReasonChanSend, traceEvGoBlockSend, 2)
	// Ensure the value being sent is kept alive until the
	// receiver copies it out. The sudog has a pointer to the
	// stack object, but sudogs aren't considered as roots of the
	// stack tracer.
	// 防止变量被CG
	KeepAlive(ep)
```

这里先通过`getg`获取当前的`goroutine`，然后调用`acquireSudog`方法构造`sudog`结构体，然后设置待发送消息和`goroutine`等信息（`sudog`通过`g`绑定`goroutine`，而`goroutine`通过waiting绑定`sudog`），构造完毕后通过`c.sendq.enqueue`放入待发送的等待队列，最后调用`gopark`方法挂起当前的`goroutine`进入`wait`状态。

此时`goroutine`处于`wait`状态，等待被唤醒

```go
// goroutine被唤醒，表示数据已经发送完成，做清理工作
	// someone woke us up.
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
	return true
```

唤醒的逻辑就是判断`goroutine`是否存在，检查当前`channel`是否被关闭了。取消`goroutine`和`sudog`的绑定。

## 出队

`channel`结构数据有两种方式：

```go
val := <- ch
val,ok := <- ch
```

它们在编译器编译后的分别对应的是`runtime.chanrecv1`和`runtime.chanrecv2`：

```go
// entry points for <- c from compiled code
//go:nosplit
func chanrecv1(c *hchan, elem unsafe.Pointer) {
	chanrecv(c, elem, true)
}

//go:nosplit
func chanrecv2(c *hchan, elem unsafe.Pointer) (received bool) {
	_, received = chanrecv(c, elem, true)
	return
}
```

其实都是调用`chanrecv`方法

### 前置检查

```go
// chan为nil，非阻塞直接返回，阻塞就等待并抛出异常
	if c == nil {
		if !block {
			return
		}
		gopark(nil, nil, waitReasonChanReceiveNilChan, traceEvGoStop, 2)
		throw("unreachable")
	}
	if !block && (c.dataqsiz == 0 && c.sendq.first == nil ||
		c.dataqsiz > 0 && atomic.Loaduint(&c.qcount) == 0) &&
		atomic.Load(&c.closed) == 0 {
		return
	}

	var t0 int64
	if blockprofilerate > 0 {
		t0 = cputicks()
	}
```

判断当前`channel`是否为`nil`，如果为`nil`则为非阻塞接受，直接返回。如果`nil channel`为阻塞接受，会调用`gopark`挂起。

当循环队队列为0且等待队列`sendq`内没有`goroutine`正在等待或等待队列为空时，直接返回。

这里把判断`channel`是否关闭放在最后判断，是因为如果放在前面判断，判断到后面条件时，`closed`状态可能会被改变。

### 加锁/异常检查

```go
	lock(&c.lock)

	// 如果通道已经关闭并且没有数据可以读取，返回(true,false)
	if c.closed != 0 && c.qcount == 0 {
		unlock(&c.lock)
		if ep != nil {
			typedmemclr(c.elemtype, ep)
		}
		return true, false
	}
```

如果`channel`被关闭了，并且缓存区没有数据，则直接释放锁和清理`ep`中的指针数据。

### channel直接接收数据

```go
// 场景一：如果有发送者在队列中等待，那么直接从发送者提取数据，并唤醒发送者。
	if sg := c.sendq.dequeue(); sg != nil {
		// Found a waiting sender. If buffer is size 0, receive value
		// directly from sender. Otherwise, receive from head of queue
		// and add sender's value to the tail of the queue (both map to
		// the same buffer slot because the queue is full).
		recv(c, sg, ep, func() { unlock(&c.lock) }, 3)
		return true, true
	}
```

这一步与`channel`直接发送数据是对应的，当发现`channel`上有阻塞的等待发送的发送方时，则直接进行接收。

等待发送队列中有`goroutine`存在，有两种可能：

- 非缓冲的`channel`
- 缓冲的`channel`，但是缓冲区满了

针对这两种情况，在`recv`中有不同的行为：

```go
// 如果无缓冲，直接取出数据；如果有缓冲，将缓冲区的数据取出来，然后将等待中的发送者的数据拷贝到缓冲区中
func recv(c *hchan, sg *sudog, ep unsafe.Pointer, unlockf func(), skip int) {
	if c.dataqsiz == 0 { // 如果不带缓冲区
		if ep != nil {
			// copy data from sender
			// 直接从发送者复制数据到ep
			recvDirect(c.elemtype, sg, ep)
		}
	} else {
		// Queue is full. Take the item at the
		// head of the queue. Make the sender enqueue
		// its item at the tail of the queue. Since the
		// queue is full, those are both the same slot.
		// 如果带缓冲区，由于有发送者等待，所以缓冲区一定是满的。将缓冲区的第一个数据复制到ep，然后将发送者的数据赋值到缓冲区
		qp := chanbuf(c, c.recvx)
		// copy data from queue to receiver
		if ep != nil {
			typedmemmove(c.elemtype, ep, qp)
		}
		// copy data from sender to queue
		typedmemmove(c.elemtype, qp, sg.elem)
		c.recvx++
		if c.recvx == c.dataqsiz {
			c.recvx = 0
		}
		c.sendx = c.recvx // c.sendx = (c.sendx+1) % c.dataqsiz
	}
	sg.elem = nil
	gp := sg.g
	unlockf()
	gp.param = unsafe.Pointer(sg)
	if sg.releasetime != 0 {
		sg.releasetime = cputicks()
	}
	// 将发送者唤醒
	goready(gp, skip+1)
}
```

这里主要就是分两种情况：

- 非缓冲`channel`：未忽略接受值时直接调用`recvDirect`方法直接从发送方的`goroutine`调用栈中将数据拷贝到接收方的`goroutine`
- 带缓冲区的`channel`：调用`chanbuf`方法根据`recv`索引的位置读取缓冲区元素，并将其拷贝到接收方的内存地址，拷贝完成后调整`sendx`和`recvx`索引的位置。

最后`goready`唤醒发送方的`goroutine`继续发送数据。

### channel缓冲区有数据

```go
// 场景二：如果缓冲区有数据，从缓冲区复制数据到ep，并且修改下次接收位置和qcount
	if c.qcount > 0 {
		// Receive directly from queue
		// 存元素
		qp := chanbuf(c, c.recvx)
		if raceenabled {
			raceacquire(qp)
			racerelease(qp)
		}
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

### channel缓冲区无数据

```go
// 执行上面的流程后，仍然没有返回，说明缓冲区没有数据，且没有发送者在等待。
	// 如果是非阻塞，直接返回(false,false)(走default)
	if !block {
		unlock(&c.lock)
		return false, false
	}
```

```go
// 对于阻塞接收的情况，将调用者goroutine挂起，并且等待被唤醒
	gp := getg()
	mysg := acquireSudog()
	mysg.releasetime = 0
	if t0 != 0 {
		mysg.releasetime = -1
	}
	// No stack splits between assigning elem and enqueuing mysg
	// on gp.waiting where copystack can find it.
	mysg.elem = ep
	mysg.waitlink = nil
	gp.waiting = mysg
	mysg.g = gp
	mysg.isSelect = false
	mysg.c = c
	gp.param = nil
	// goroutine 作为一个 waiter 入队列，等待条件满足之后，从这个队列里取出来唤醒；
	c.recvq.enqueue(mysg)
	// Signal to anyone trying to shrink our stack that we're about
	// to park on a channel. The window between when this G's status
	// changes and when we set gp.activeStackChans is not safe for
	// stack shrinking.
	atomic.Store8(&gp.parkingOnChan, 1)
	gopark(chanparkcommit, unsafe.Pointer(&c.lock), waitReasonChanReceive, traceEvGoBlockRecv, 2)
```

剩下的就是被唤醒后清理现场。

## 关闭channel

```go
// 关闭通道
func closechan(c *hchan) {
	if c == nil {
		panic(plainError("close of nil channel"))
	}

	lock(&c.lock)
	// 不能对已经关闭的通道再次执行关闭操作
	if c.closed != 0 {
		unlock(&c.lock)
		panic(plainError("close of closed channel"))
	}

	if raceenabled {
		callerpc := getcallerpc()
		racewritepc(c.raceaddr(), callerpc, funcPC(closechan))
		racerelease(c.raceaddr())
	}

	// 设置关闭标识
	c.closed = 1

	var glist gList // g对象的列表

	// 唤醒所有的接受者，将接收数据置0
	for {
		sg := c.recvq.dequeue()
		if sg == nil {
			break
		}
		if sg.elem != nil {
			typedmemclr(c.elemtype, sg.elem)
			sg.elem = nil
		}
		if sg.releasetime != 0 {
			sg.releasetime = cputicks()
		}
		gp := sg.g
		gp.param = nil
		if raceenabled {
			raceacquireg(gp, c.raceaddr())
		}
		glist.push(gp)
	}

	// 唤醒所有的发送者，令其panic
	for {
		sg := c.sendq.dequeue()
		if sg == nil {
			break
		}
		sg.elem = nil
		if sg.releasetime != 0 {
			sg.releasetime = cputicks()
		}
		gp := sg.g
		gp.param = nil
		if raceenabled {
			raceacquireg(gp, c.raceaddr())
		}
		glist.push(gp)
	}
	unlock(&c.lock)

	// Ready all Gs now that we've dropped the channel lock.
	for !glist.empty() {
		gp := glist.pop()
		gp.schedlink = 0
		goready(gp, 3)
	}
}
```

- 不允许对`nil`的channel进行关闭
- 不允许重复关闭channel
- 获取当前正在阻塞的发送或接受的`goroutine`，此时它们处于挂起状态，然后将它们唤醒。这是发送方不允许向channel发送数据，但不影响接收方继续接受数据，如果没有元素，获取到的元素为零值。

## 总结

channel的设计不是特别复杂，本质上就是维护了一个循环队列，发送数据依赖于`FIFO`，数据传递依赖于内存拷贝。