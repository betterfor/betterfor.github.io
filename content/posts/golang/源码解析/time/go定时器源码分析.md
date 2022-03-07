---
title: "Go定时器源码分析"
date: 2021-07-01T15:44:20+08:00
draft: false

tags: ['源码解析','time']
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: true
---

虽然golang的定时器经过几版的改进优化，但是仍然是性能的大杀手。

## golang1.13和1.14的区别

golang在1.10版本之前是由一个独立的`timerproc`通过小顶堆和`futexsleep`来管理定时任务。1.10版本之后是把独立的`timerproc`和小顶堆分成最多64个`timerproc`协程和四叉堆，用来休眠的方式还是 [futexsleep](https://github.com/golang/go/blob/go1.13.15/src/runtime/os_linux.go#L15)

而1.14版的timer是把存放定时事件的四叉堆放到了`P`结构中，同时取消了`timerproc`协程，转而使用`netpoll`的`epoll wait`来做就近时间的休眠等待。

## 函数签名

对于`NewTimer`函数，我们可以找到实现 [time/sleep.go#L82](https://github.com/golang/go/blob/e71b61180aa19a60c23b3b7e3f6586726ebe4fd1/src/time/sleep.go#L82)。其实我们可以发现，`NewTimer`、`NewTicker`、`After`其实都是调用`addTimer`来新增定时任务。

```go
type Timer struct {
	C <-chan Time
	r runtimeTimer
}

// NewTimer creates a new Timer that will send
// the current time on its channel after at least duration d.
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

func sendTime(c interface{}, seq uintptr) {
	select {
	case c.(chan Time) <- Now():
	default:
	}
}

func NewTicker(d Duration) *Ticker {
	if d <= 0 {
		panic(errors.New("non-positive interval for NewTicker"))
	}
	c := make(chan Time, 1)
	t := &Ticker{
		C: c,
		r: runtimeTimer{
			when:   when(d),
			period: int64(d),
			f:      sendTime,
			arg:    c,
		},
	}
	startTimer(&t.r)
	return t
}
```

这里主要分成两步：

1、创建一个`Timer`对象，包含一个具有缓冲区channel的`c`，用来接收`Timer`消息的，包含的`runtimeTimer`结构体，`when`是代表`timer`触发的绝对时间(当前时间+d)，`f`是`timer`触发时的回调函数，`arg`是传给`f`的参数。

2、调用`startTimer`，实际上是调用`runtime`包下的`addtimer`函数。

3、`NewTicker`调用的是相同的函数，只是多了一个字段`period`，表示计时器再次被唤醒的时间，做轮询触发。

## golang1.13的定时器原理

首先会初始化一个长度为64的`timers`数组，通过协程的`p`的`id`取模来分配`timersBucket`，如果发现新的定时任务比较新，那么调用`notewakeup`来激活唤醒`timerproc`的`futex`等待。如果发现没有实例化`timerproc`，则启动。

### 1、添加定时器

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

### 2、timersBucket

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

在`runtime`中，有64个全局定义的`timer bucket`。每个`bucket`负责管理`timer`。`timer`的整个生命周期包括创建、销毁、唤醒、睡眠等都是由`timer bucket`管理和调度。

> 问：为什么是64个`timer bucket`?
>
> 答：在1.10版本之前，只有1个`timers`对象，在添加定时器任务时都需要对`timers`进行加锁和解锁操作，影响性能；当`timer`过多，`timers`中的`t`很多，添加进四叉堆操作可能耗时比较长，可能会导致`timer`的延迟。因此引入全局64个分桶的策略，将`timer`分散到桶中，每个桶只负责自己的`timer`，有效降低了锁的粒度和`timer`调度的负担。
>
> 而根据最优的情况下，应该是分桶的数量应该要和`GOMAXPROCS`数量一致，有多少个`P`就有多少个`timer bucket`。但是，这就涉及到`P`的动态分配问题，所以在性能的权衡下，使用64 能够覆盖大多数的场景。

### 3、分配桶

```go
func (t *timer) assignBucket() *timersBucket {
	id := uint8(getg().m.p.ptr().id) % timersLen
	t.tb = &timers[id].timersBucket
	return t.tb
}
```

### 4、添加timer到四叉堆

```go
func (tb *timersBucket) addtimerLocked(t *timer) bool {
	// 此时when应该是当前时间+duration
	if t.when < 0 {
		t.when = 1<<63 - 1
	}
	// 将timer添加到四叉堆中
	t.i = len(tb.t)
	tb.t = append(tb.t, t)
	if !siftupTimer(tb.t, t.i) {
		return false
	}
	// 首次添加
	if t.i == 0 {
		// 如果timerproc在sleep，唤醒它
		if tb.sleeping && tb.sleepUntil > t.when {
			tb.sleeping = false
			notewakeup(&tb.waitnote)
		}
		// 如果timerproc被挂起了，重新调度
		if tb.rescheduling {
			tb.rescheduling = false
			goready(tb.gp, 0)
		}
		// 如果timer的桶还没有创建，创建并开始timerproc
		if !tb.created {
			tb.created = true
			go timerproc(tb)
		}
	}
	return true
}
```

> 问：为什么是四叉堆？
>
> 答：上推节点的操作更快；对缓存更友好。

### 5、timerproc

```go
// timerproc 外层循环不会退出
func timerproc(tb *timersBucket) {
	tb.gp = getg()
	for {
		lock(&tb.lock)
		// 修改睡眠标识
		tb.sleeping = false
		// 当前时间
		now := nanotime()
		delta := int64(-1)
		for {
			// 如果桶内没有timer，退出
			if len(tb.t) == 0 {
				delta = -1
				break
			}
			// 获取最早触发的timer
			t := tb.t[0]
			delta = t.when - now
			// 还没有到达触发时间，退出
			if delta > 0 {
				break
			}
			ok := true
			if t.period > 0 {
				// 需要周期性触发定时器，需要修改timer的触发时间，重新添加到最小堆中
				// leave in heap but adjust next time to fire
				t.when += t.period * (1 + -delta/t.period)
				if !siftdownTimer(tb.t, 0) {
					ok = false
				}
			} else {
				// 从最小堆中移除
				last := len(tb.t) - 1
				if last > 0 {
					tb.t[0] = tb.t[last]
					tb.t[0].i = 0
				}
				tb.t[last] = nil
				tb.t = tb.t[:last]
				if last > 0 {
					if !siftdownTimer(tb.t, 0) {
						ok = false
					}
				}
				t.i = -1 // 下标标记为-1，deltimer发现下标为-1时就不删除了
			}
			f := t.f
			arg := t.arg
			seq := t.seq
			unlock(&tb.lock)
			if !ok {
				badTimer()
			}
			if raceenabled {
				raceacquire(unsafe.Pointer(t))
			}
			f(arg, seq)
			lock(&tb.lock)
		}
		if delta < 0 || faketime > 0 {
			// 如果桶中没有timer，把协程挂起
			tb.rescheduling = true
			goparkunlock(&tb.lock, waitReasonTimerGoroutineIdle, traceEvGoBlock, 1)
			continue
		}
		// 如果还有timer，睡眠到桶内最早触发的时间点后唤醒
		tb.sleeping = true
		tb.sleepUntil = now + delta
		noteclear(&tb.waitnote)
		unlock(&tb.lock)
		notetsleepg(&tb.waitnote, delta)
	}
}
```

### 6、小结

1、首选预分配64个的`timer bucket`，`timer bucket`里面是一个四叉堆存放`timer`

2、每次新增的`timer`，添加到四叉堆中，会尝试唤醒和调度`bucket`

3、第一次新增的`bucket`会运行协程`timerproc`。`timerproc`是一个死循环，周期性地检查定时器状态。

4、每次从最小堆中取出`timer`，如果是计时器，则重新加入到`bucket`中。如果`bucket`没有`timer`，则将`timerproc`挂起。如果还有`timer`，则睡眠到`bucket`中堆顶唤醒的时间。

## 深度分析golang1.14定时器

### 1、timer

```go
type timer struct {
	// If this timer is on a heap, which P's heap it is on.
	// puintptr rather than *p to match uintptr in the versions
	// of this struct defined in other packages.
	pp puintptr	// 计时器所在的处理器P的指针地址

	// Timer wakes up at when, and then at when+period, ... (period > 0 only)
	// each time calling f(arg, now) in the timer goroutine, so f must be
	// a well-behaved function and not block.
	when   int64		// 计时器被唤醒的时间
	period int64		// 计时器再次被唤醒的时间（周期）
	f      func(interface{}, uintptr)	// 回调函数，每次在计时器被唤醒时都会调用
	arg    interface{}	// 回调函数的参数
	seq    uintptr		// 回调函数的参数，仅在netpoll的应用场景下使用

	// What to set the when field to in timerModifiedXX status.
	nextwhen int64	// 当计时器状态为timerModifiedXX时，将会使用nextwhen设置到where字段上

	// The status field holds one of the values below.
	status uint32	// 计时器当前的状态值
}
```

### 2、p

在添加方式上，go1.14发生了变更，改为将每个`timer`存储在处理器`p`上。这也是我们之前提到的优化结构，64只能泛指大多数情况，实际都是需要`p`进行处理。所以go1.14里的`p`结构中有了`timers`字段。

```go
type p struct {
    ...
    timersLock mutex
    timers []*timer
    ...
}
```

同样，在`timers`数组仍是一个最小四叉堆。

### 3、定时器状态

```go
// Values for the timer status field.
const (
	// timer尚未设置状态
	timerNoStatus = iota

	// 等待timer启动
	timerWaiting

	// 运行timer的回调方法
	timerRunning

	// timer已经被删除，但仍然在某些p的堆中
	timerDeleted

	// timer即将被删除
	timerRemoving

	// timer已经停止，且不存在任何p的堆中
	timerRemoved

	// timer正在被修改
	timerModifying

	// timer已被修改为更早的时间，新的时间被设置在nextwhen字段中，
	timerModifiedEarlier

	// timer已被修改为更迟的时间，新的时间被设置在nextwhen字段中，
	timerModifiedLater
	
	// timer已经被修改，正在被移动
	timerMoving
)
```

因为涉及到`p`的管理，所以新增了10个`timer`的状态管理。

### 4、启动定时器

```go
func addtimer(t *timer) {
	// when must never be negative; otherwise runtimer will overflow
	// during its delta calculation and never expire other runtime timers.
	// 边界条件判断
	if t.when < 0 {
		t.when = maxWhen
	}
	// timer的状态为timerNoStatus
	if t.status != timerNoStatus {
		throw("addtimer called with initialized timer")
	}
	t.status = timerWaiting

	when := t.when

	pp := getg().m.p.ptr()
	lock(&pp.timersLock)
	// 清除处理器p中的计时器队列，可以加快创建和删除计时器的程序的速度
	cleantimers(pp)		
	// 将当前所新创建的timer新增到p的堆中
	doaddtimer(pp, t)
	unlock(&pp.timersLock)

	// 唤醒网络轮询器中休眠的线程，检查timer被唤醒的时间(when)是否在当前轮询预期运行的时间(pollerPollUntil)内，若是则唤醒
	wakeNetPoller(when)
}
```

添加`timer`到当前的`p`上，这应该只在一个新创建的timer中调用，这避免了更改某些`p`的最小堆`timer`的`when`字段的风险，因为这可能导致最小堆乱序。

### 5、停止定时器

在定时器的运行中，一般会调用`timer.Stop`方法来停止/删除定时器，其实就是让这个`timer`从处理器`p`的堆中移除。

- timerWaiting/timerModifiedLater：修改`timer`状态为timerDeleted，删除数量+1
- timerModifiedEarlier：修改`timer`状态为timerDeleted，删除数量+1，adjustTimers+1
- timerDeleted/timerRemoving/timerRemoved：无需变更，已经满足条件
- timerRunning/timerMoving/timerModifying：正在执行、移动中，无法停止，等待下一次状态检查再处理
- timerNoStatus：无法停止，不满足条件

### 6、修改/重置定时器

在程序调度中，有些因为逻辑改变，需要重置定时器。一般会调用`timer.Reset()`来重设`Duration`值。

```go
func resettimer(t *timer, when int64) {
	modtimer(t, when, t.period, t.f, t.arg, t.seq)
}
```

实际调用`modtimer`方法。

- timerRunning/timerRemoving/timerMoving/timerModifying：等待状态改变
- timerDeleted->timerModifying->timerModifiedXXX
- timerNoStatus/timerRemoved->timerModifying->timerWaiting
- timerWaiting/timerModifiedXXX->timerModifying->timerModifiedXXX

在处理完处理器的状态后，会分为两种情况进行处理：

1、待修改的定时器已经被删除：由于原定时器没有了，所以会调用`doaddtimer`方法创建一个定时器，并赋值原先的`timer`，再调用`wakeNetPoller`在预定的时间唤醒网络轮询器

2、正常逻辑处理：如果修改后的定时器的触发时间小于原本的触发是按，则修改定时器状态为timerModifiedEalier，并调用`wakeNetPoller`在预定的时间唤醒网络轮询器

### 7、触发定时器

前面提到过，`timers`已经归属到`p`中去了，所以定时器的触发分成两个部分：

- 通过调度器在调度时进行定时器的触发
- 通过系统监控检查并触发定时器（到期未执行）

#### 1、调度器触发

调度器触发一般分为两种情况。

一种是调度循环中调用`checkTimers`方法进行计时器的触发

```go
func schedule() {
    _g_ := getg()
    ...
top:
	pp := _g_.m.p.ptr()
	pp.preempt = false
    ...
    checkTimers(pp, 0)
    ...
    execute(gp, inheritTime)
}
```

另一种是当前处理器`p`没有可执行的`timer`，且没有可执行的`G`。那么按照调度模型，就会去窃取其他定时器和`G`:

```go
func findrunnable() (gp *g, inheritTime bool) {
    _g_ := getg()
    ...
top:
	_p_ := _g_.m.p.ptr()
    ...
    now, pollUntil, _ := checkTimers(_p_, 0)
    ...
}
```

---

我们来进一步分析`checkTimers`方法：

1、检查处理器`p`上是否有需要处理的`timer`

2、如果没有需要执行的`timer`，则直接返回；否则，判断标记为删除的`timer`数量如果小于`p`上的`timer`数量则直接返回

3、对需要处理的`timer`，根据时间将`timers`重新排序

4、在调整完`timers`后，调用`runtimer`方法真正执行`timer`，触发定时器

5、在最后的阶段，如果被标记为删除的`timer`数量如果大于`p`上的`timer`数量，则对标记为删除的`timer`进行清理。

#### 2、系统监控触发

通过每次调度器调度和窃取的是否触发，还是有一定的随机性。

因此需要一个系统监控来触发定时器。

```go
func sysmon() {
	...
	for {
		...
		next, _ := timeSleepUntil()
		if debug.schedtrace <= 0 && (sched.gcwaiting != 0 || atomic.Load(&sched.npidle) == uint32(gomaxprocs)) {
			lock(&sched.lock)
			if atomic.Load(&sched.gcwaiting) != 0 || atomic.Load(&sched.npidle) == uint32(gomaxprocs) {
				if next > now {
					atomic.Store(&sched.sysmonwait, 1)
					unlock(&sched.lock)
					// Make wake-up period small enough
					// for the sampling to be correct.
					sleep := forcegcperiod / 2
					if next-now < sleep {
						sleep = next - now
					}
					shouldRelax := sleep >= osRelaxMinNS
					if shouldRelax {
						osRelax(true)
					}
					notetsleep(&sched.sysmonnote, sleep)
					if shouldRelax {
						osRelax(false)
					}
					now = nanotime()
					next, _ = timeSleepUntil()
					lock(&sched.lock)
					atomic.Store(&sched.sysmonwait, 0)
					noteclear(&sched.sysmonnote)
				}
				idle = 0
				delay = 20
			}
			unlock(&sched.lock)
		}
		...
		// poll network if not polled for more than 10ms
		lastpoll := int64(atomic.Load64(&sched.lastpoll))
		if netpollinited() && lastpoll != 0 && lastpoll+10*1000*1000 < now {
			atomic.Cas64(&sched.lastpoll, uint64(lastpoll), uint64(now))
			list := netpoll(0) // non-blocking - returns list of goroutines
			if !list.empty() {
				incidlelocked(-1)
				injectglist(&list)
				incidlelocked(1)
			}
		}
        if next < now {
			startm(nil, false)
		}
		...
	}
}
```

1、在每次系统监控时，都会在流程上调用`timeSleepUntil`方法去获取下一个定时器应触发的时间，以及保存改定时器已经打开的定时器堆的`p`.

2、检查当前是否存在GC，若正在STW则获取调度互斥锁。若发现下一个`timer`触发时间已经过去，则重新调用`timeSleepUntil`获取下一个定时器的时间和相应的`p`。

3、如果发现超过10ms没有进行`netpoll`网络轮询，则主动调用`netpoll`方法触发轮询

### 8、运行定时器

这里来分析一下`runtimer`方法：

只有被标记为`timerWaiting`状态的定时器才能运行，尝试将状态更新为`timerRunning`，然后执行`runOneTimer`方法。

标记为`timerDeleted`状态的定时器会去删除定时器，标记为`timerModifiedXXX`状态的定时器会去重新添加定时器。

```go
func runOneTimer(pp *p, t *timer, now int64) {
	f := t.f
	arg := t.arg
	seq := t.seq

	if t.period > 0 {
		// ticker，需要再次触发
		// 重新计算下一次的触发时间，并且更新其在最小堆
		delta := t.when - now
		t.when += t.period * (1 + -delta/t.period)
		siftdownTimer(pp.timers, 0)
		// 将状态修改为timerWaiting
		if !atomic.Cas(&t.status, timerRunning, timerWaiting) {
			badTimer()
		}
		// 设置p的下一次触发时间
		updateTimer0When(pp)
	} else {
		// 移除timer
		dodeltimer0(pp)
		if !atomic.Cas(&t.status, timerRunning, timerNoStatus) {
			badTimer()
		}
	}

	unlock(&pp.timersLock)

	// 回调方法
	f(arg, seq)

	lock(&pp.timersLock)
}
```

### 9、小结

通过大致的go1.14源码分析，可以看出有以下改变：

- 在每个处理器`p`中，`timers`以最小四叉堆方式存储
- 在调度器的每轮跳读中都会对定时器进行触发和检查
- 在系统监听`netpoll`会定时进行定时器的触发和检查
- 在定时器的处理中，10个状态的流转和处理变化

## 总结

go1.13最多可以开到GOMAXPROCS数量的timerproc协程，当然不超过64。但我们要知道timerproc自身就是协程，也需要runtime pmg的调度。反而go 1.14把检查到期定时任务的工作交给了runtime.schedule，不需要额外的调度，每次runtime.schedule和findrunable时直接运行到期的定时任务。

线程上下文切换开销？新添加的定时任务的到期时间更小时，不管是使用futex还是epoll_wait系统调用都会被唤醒重新休眠，被唤醒的线程会产生上下文切换。但由于go1.14没有timerproc的存在，新定时任务可直接插入或多次插入后再考虑是否休眠。

结论，golang 1.13的定时器在任务繁多时，必然会造成更多的上线文切换及runtime pmg调度，而golang 1.14做了更好的优化。