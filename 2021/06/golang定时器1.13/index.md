# Golang定时器1.13源码分析


本文将基于Golang源码对Timer的底层实现进行深度剖析。

注：**本文基于golang-1.13源码进行分析**。

## 概述

我们在开发过程中通常会用到`time.NewTimer`和`time.NewTicker`进行定时或延迟操作，而`Timer`和`Ticker`的底层实现大致相同，本文主要对`Timer`进行源码解析。

`Timer`的使用方法如下：

```go
timer := time.NewTimer(time.Second)
<-timer.C
```

使用`time.NewTimer`构造一个1秒的定时器，同时使用`<-timer.C`阻塞等待定时器的触发。

## 底层实现

对于`NewTimer(d Duration) *Timer` 函数，我们可以在源码中找到它的实现，在[time/sleep.go#L82](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/time/sleep.go#L82)

```go
func NewTimer(d Duration) *Timer {
	c := make(chan Time, 1)
	t := &Timer{
		C: c,
		r: runtimeTimer{
			when: when(d),
			f:    sendTime,
			arg:  c,
		},
	}
	startTimer(&t.r)
	return t
}
```

这里主要分成两步：

1、创建一个`Timer`的对象，包含一个有缓冲channel的c，用来接收`Timer`触发消息的，包含`runtimeTimer`结构体，`when`是代表timer触发的绝对时间(当前时间+d)，`f`是timer触发时的回调函数，`arg`就是传给`f`的参数。

2、调用`startTimer`函数，顾名思义，就是启动`timer`。

具体的逻辑都在`startTimer`中,而`startTimer`具体的函数定义在[runtime/time.go#L110](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/runtime/time.go#L110)，而它实际上调用的是[`addTimer`](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/runtime/time.go#L131)

```go
func addtimer(t *timer) {
	tb := t.assignBucket()
	lock(&tb.lock)
	ok := tb.addtimerLocked(t)
	unlock(&tb.lock)
	if !ok {
		badTimer()
	}
}
```

可以看到`addtimer`做了两件事：

1、`assignBucket`找到可以被插入的`bucket`

2、`addtimerLocked`将`timer`插入到`bucket`

那么`bucket`是什么？`timer`是怎么插入到`bucket`中的？`timer`到期后又是怎么触发的？

接下来我们来详细看看这个`bucket`

## TimerBucket

```go
const timersLen = 64

// timer包含每个P的堆，timer进入队列中关联当前的P，所以每个P中timer都是独立于其他P的
// 如果GOMAXPROCS > timersLen，那么timersBucket可能会管理多个P
var timers [timersLen]struct {
	timersBucket

	// 内存对齐
	pad [cpu.CacheLinePadSize - unsafe.Sizeof(timersBucket{})%cpu.CacheLinePadSize]byte
}

type timersBucket struct {
	lock         mutex
	gp           *g
	created      bool
	sleeping     bool
	rescheduling bool
	sleepUntil   int64
	waitnote     note
	t            []*timer
}
```

在`runtime`中，有64个全局的`timer bucket`。每个`bucket`负责管理`timer`。`timer`的整个生命周期包括创建、销毁、唤醒和睡眠等都由`timer bucket`管理和调度。

### timer bucket

每个`timer bucket`实际上内部使用最小四叉堆来存储和管理每个timer。最小堆是常见的数据结构，具体实现类似于二叉树。在最小堆中，作为排序依据的`key`是`timer`的`when`属性，也就是何时触发。即最近一次触发的`timer`会在栈顶。

### timerproc调度

每个`timer bucket`负责管理一堆有序的`timer`，同时每个`timer bucket`都有一个对应的`timerproc`的goroutine来负责不断调度这些`timer`。代码在[runtime/time.go#L169](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/runtime/time.go#L169)

`timeproc`的整个流程如下：

1、创建：虽然`timer bucket`一直都存在，但是`timerproc`的协程并不是一开始就存在，而是第一个`timer`被加到`timer bucket`中，判断`tb.created`后，才创建一个goroutine

2、调度：从`timer bucket`不断取栈顶元素，如果栈顶的`timer`已触发，则将其从最小堆中移除，并调用对应的callback(`sendTime`)

3、如果`timer`是`ticker`(周期性`timer`)，则生成新的`timer`塞进`timer bucket`

4、挂起：如果`timer bucket`为空，意味着所有的`timer`已经被消费完了，则调用`gopark`挂起该goroutine

5、唤醒：当有新的timer被添加到`timer bucket`,如果goroutine处于挂起状态，会调用`goready`唤醒`timerproc`

当`timer`触发时，触发的`sendTime`函数如下

```go
func sendTime(c interface{}, seq uintptr) {
	select {
	case c.(chan Time) <- Now():
	default:
	}
}
```

对于`ticket`，`sendTime`会被调用多次，而channel的缓冲长度只有1，如果`ticket`没有及时消费，会被丢弃。

## 为什么是64个timer bucket?

在go1.10之前，只有一个`timers`，负责管理`timer`，没有桶，但是问题非常明显：

1、创建和停止`timer`都需要对`timers`进行加锁操作

2、当`timer`过多时，调度负担重，可能会造成延迟

因此，在go1.10时引入了全局64个分桶的策略，将`timer`分散到分桶中，每个桶负责自己分配到的timer即可。有效地降低了锁的粒度和`timer`调度的负担。

而关于为什么是64个？

这是因为理想情况下，分桶的数量和`GOMAXPROCS`一致是最优解，有多少个P就有多少个`timer bucket`。但是，这涉及到了go启动时的动态内存分配，作为`runtime`减少程序负担，所以在内存使用和性能之间权衡下，使用64能覆盖大多数的`GOMAXPROCS`。

每个`bucket`具体负责的`timer`和P相关

```go
func (t *timer) assignBucket() *timersBucket {
	id := uint8(getg().m.p.ptr().id) % timersLen
	t.tb = &timers[id].timersBucket
	return t.tb
}
```

如果`GOMAXPROCS`>64，会导致`timer bucket`会关联多个P上的`timer`。

## 为什么是四叉堆？

[*d*-ary heap](https://en.wikipedia.org/wiki/D-ary_heap)

> 4-heaps may perform better than binary heaps in practice, even for delete-min operations.

## sleep实现

我们可以使用定时器来实现`Sleep`，但是底层却不是这么做的。[runtime/time.go#L84](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/runtime/time.go#L84) 

```go
func timeSleep(ns int64) {
	if ns <= 0 {
		return
	}

	gp := getg()
	t := gp.timer
	if t == nil {
		t = new(timer)
		gp.timer = t
	}
	*t = timer{}
	t.when = nanotime() + ns
	t.f = goroutineReady
	t.arg = gp
	tb := t.assignBucket()
	lock(&tb.lock)
	if !tb.addtimerLocked(t) {
		unlock(&tb.lock)
		badTimer()
	}
	goparkunlock(&tb.lock, waitReasonSleep, traceEvGoSleep, 2)
}
```

1、每个goroutine底层的G对象上，都有一个timer属性，这个是runtimeTimer对象，专门用来sleep使用。当第一次调用sleep时，都会创建runtimeTimer，之后sleep的时候会一直复用这个对象

2、调用sleep，触发timer后，直接gopark，将当前goroutine挂起

3、timerproc调用callback时，调用的是goroutineReady，唤醒被挂起的goroutine


