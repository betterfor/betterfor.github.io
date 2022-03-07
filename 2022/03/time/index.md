# 计时器的设计


在我们编码过程中，经常会用到与时间相关的需求。而关于时间转换之类的比较简单，那么计时器经过了以下几个版本的迭代：

- Go1.9版本之前，计时器由全局唯一的四叉堆维护
- Go1.10~1.13，全局由64个四叉堆维护，每个P创建的计时器会由对应的四叉堆维护
- Go1.14版本之后，每个处理器单独维护计时器并通过网络轮询器触发

## 一、计时器设计

### 1.1、全局四叉堆

Go1.10之前的计时器的结构体如下所示

```go
# https://github.com/golang/go/blob/go1.9.7/src/runtime/time.go#L28
var timers struct {
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

注意这个结构体是用`var`变量定义的，它会存储所有的计时器。`t`就是最小四叉堆，运行时创建的所有计时器都会加入到四叉堆中。

由一个独立的`timerproc`通过最小四叉堆和`futexsleep`来管理定时任务。

### 1.2、64个四叉堆

但是全局四叉堆共用一把锁对性能的影响非常大，所以Go1.10之后将全局四叉堆分割成了64个更小的四叉堆。

```go
# https://github.com/golang/go/blob/go1.13.15/src/runtime/time.go#L39
const timersLen = 64
var timers [timersLen]struct {
	timersBucket
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

在理想情况下，四叉堆的数量应该等于处理器的数量`GOMAXPROCS`，但是需要动态获取处理的数量，所以经过权衡初始化64个四叉堆，如果当前机器的处理器P的个数超过了64个，多个处理器的计时器可能会存储在同一个桶中。

```go
func (t *timer) assignBucket() *timersBucket {
	id := uint8(getg().m.p.ptr().id) % timersLen
	t.tb = &timers[id].timersBucket
	return t.tb
}
```

将全局计时器分片，虽然能够降低锁的粒度，但是`timerproc`造成处理器和线程之间频繁的上下文切换却成为了影响计时器的瓶颈。

### 1.3、网络轮询器

在Go1.14版本之后，计时器桶`timersBucket`已经被移除了，所有的计时器都以最小四叉堆的形式存储在P中。

在`p`结构体中有以下字段与计时器关联：

- timersLock：保护计时器的互斥锁
- timers：存储计时器的最小四叉堆
- numTimers：处理器P中的计时器数量
- adjustTimers：处理器P中状态是`timerModifiedEarlier`的计时器数量
- deletedTimers：处理器P中状态是`timerDeleted`的计时器数量

而计时器的结构体为：

```go
type timer struct {
	pp puintptr
	when   int64
	period int64
	f      func(interface{}, uintptr)
	arg    interface{}
	seq    uintptr
	nextwhen int64
	status uint32
}
```

- pp：计时器所在的处理器P的指针地址
- when：当前计时器被唤醒的时间
- period：当前计时器被再次唤醒的时间
- f：回调函数，每次在计时器被唤醒时都会被调用
- arg：回调函数的参数
- seq：回调函数的参数，仅在`netpoll`的应用场景下使用
- nextwhen：当计时器状态为`timerModifiedXXX`时，将会把`nextwhen`赋值给`when`
- status：计时器状态

这个仅仅只是`runtime/time.go`运行时内部处理的结构，而真正对外暴露的计时器的结构体是：

```go
type Timer struct {
	C <-chan Time
	r runtimeTimer
}

type Ticker struct {
	C <-chan Time
	r runtimeTimer
}
```

通过channel来通知计时器时间

## 二、状态机

| 状态                 | 说明                                                      |
| -------------------- | --------------------------------------------------------- |
| timerNoStatus        | timer尚未设置状态                                         |
| timerWaiting         | 等待timer启动                                             |
| timerRunning         | 运行timer的回调方法                                       |
| timerDeleted         | timer已经被删除，但仍然在某些p的堆中                      |
| timerRemoving        | timer即将被删除                                           |
| timerRemoved         | timer已经停止，且不存在任何p的堆中                        |
| timerModifying       | timer正在被修改                                           |
| timerModifiedEarlier | timer已被修改为更早的时间，新的时间被设置在nextwhen字段中 |
| timerModifiedLater   | timer已被修改为更迟的时间，新的时间被设置在nextwhen字段中 |
| timerMoving          | timer已经被修改，正在被移动                               |

在`runtime/time.go`文件下，我们可以看到下面几个方法：

### 2.1、增加计时器`addtimer`

当通过`time.NewTimer`方法增加新的计时器时，会执行`startTimer`来增加计时器

```go
func startTimer(t *timer) {
	addtimer(t)
}
```

状态从`timerNoStatus`->`timerWaiting`，其他状态会抛出异常

```go
func addtimer(t *timer) {
	if t.when < 0 {
		t.when = maxWhen
	}
	if t.status != timerNoStatus {
		throw("addtimer called with initialized timer")
	}
	t.status = timerWaiting

	when := t.when

	pp := getg().m.p.ptr()
	lock(&pp.timersLock)
	cleantimers(pp)
	doaddtimer(pp, t)
	unlock(&pp.timersLock)

	wakeNetPoller(when)
}
```

1、调用`cleantimers`清除处理器P中的计时器，可以加快创建和删除计时器的程序速度

2、调用`doaddtimer`将当前计时器加入到处理器P的四叉堆`timers`中

3、调用`wakeNetPoller`唤醒网络轮询器中休眠的线程，检查`timer`被唤醒的时间`when`是否在当前轮询预期的运行时间内，如果是就唤醒。

### 2.2、删除计时器`deltimer`

当通过调用`timer.Stop`停止计时器时，会执行`stopTimer`来停止计时器

```go
func stopTimer(t *timer) bool {
	return deltimer(t)
}
```

`deltimer`会标记需要删除的计时器。在删除计时器的过程中，可能会遇到其他处理器P的计时器，所以我们仅仅只是将状态标记为删除，处理器P执行删除操作。

- `timerWaiting` -> `timerModifying` -> `timerDeleted`
- `timerModifiedLater` -> `timerModifying` -> `timerDeleted`
- `timerModifiedEarlier` -> `timerModifying`  -> `timerDeleted`
- 其他状态 -> 等待状态改变或返回

### 2.3、修改计时器`modtimer`

当通过调用`timer.Reset`重置定时器时，会执行`resetTimer`来重置定时器

```go
func resettimer(t *timer, when int64) {
	modtimer(t, when, t.period, t.f, t.arg, t.seq)
}
```

`modtimer`会修改已经存在的计时器，会根据以下规则处理计时器状态

- `timerWaiting` -> `timerModifying` -> `timerMofidiedXXX`
- `timerMofidiedXXX` -> `timerModifying` -> `timerMofidiedXXX`
- `timerNoStatus` -> `timerModifying` -> `timerWaiting`
- `timerRemoved` -> `timerModifying` -> `timerWaiting`
- `timerDeleted` -> `timerModifying` -> `timerMofidiedXXX`
- 其他状态 -> 等待状态改变

状态为`timerNoStatus`, `timerRemoved`会被标记为已删除`wasRemoved`，就会调用`doaddtimer`新创建一个计时器。

而在正常情况下会根据修改后的时间进行不同的处理：

- 修改时间 >= 修改前的时间，设置状态为`timerModifiedLater`
- 修改时间 < 修改前的时间，设置状态为`timerModifiedEarlier`，并调用`wakeNetPoller`触发调度器重新调度

### 2.4、清除定时器`cleantimers`

会根据状态清除处理器P的最小四叉堆队头的计时器

- `timerDeleted` -> `timerRemoving` -> `timerRemoved`
- `timerModifiedEarlier` -> `timerMoving` -> `timerWaiting`
- `timerModifiedLater` -> `timerMoving` -> `timerWaiting`

```go
func cleantimers(pp *p) {
	for {
		if len(pp.timers) == 0 {
			return
		}
		t := pp.timers[0]
		if t.pp.ptr() != pp {
			throw("cleantimers: bad p")
		}
		switch s := atomic.Load(&t.status); s {
		case timerDeleted:
			atomic.Cas(&t.status, s, timerRemoving)
			dodeltimer0(pp)
			atomic.Cas(&t.status, timerRemoving, timerRemoved)
		case timerModifiedEarlier, timerModifiedLater:
			atomic.Cas(&t.status, s, timerMoving)
			t.when = t.nextwhen
			dodeltimer0(pp)
			doaddtimer(pp, t)
			atomic.Cas(&t.status, timerMoving, timerWaiting)
		default:
			return
		}
	}
}
```

- 如果计时器状态为`timerDeleted`:
  - 将计时器状态改成`timerRemoving`
  - 调用`dodeltimer0`删除堆顶的计时器
  - 将计时器状态改成`timerRemoved`
- 如果计时器状态为`timerModifiedEarlier`/`timerModifiedLater`
  - 将计时器状态改成`timerMoving`
  - 使用计时器下次触发时间`nextwhen`覆盖本次时间`when`
  - 调用`dodeltimer0`删除堆顶的计时器
  - 调用`doaddtimer`将计时器加入四叉堆中
  - 将计时器状态改成`timerWaiting`

### 2.5、调整计时器`adjusttimers`

在GPM调度的时候检查计时器

- `timerDeleted` -> `timerRemoving` -> `timerRemoved`
- `timerModifiedEarlier` -> `timerMoving` -> `timerWaiting`
- `timerModifiedLater` -> `timerMoving` -> `timerWaiting`

与`cleantimers`不同的是，`adjusttimers`会遍历处理器P转给你所有的计时器

```go
func adjusttimers(pp *p) {
	if len(pp.timers) == 0 {
		return
	}
	var moved []*timer
loop:
	for i := 0; i < len(pp.timers); i++ {
		t := pp.timers[i]
		switch s := atomic.Load(&t.status); s {
		case timerDeleted:
			// 删除计时器
		case timerModifiedEarlier, timerModifiedLater:
			// 修改计时器
		case timerNoStatus, timerRunning, timerRemoving, timerRemoved, timerMoving:
		case timerWaiting:
		case timerModifying:
		default:
		}
	}

	if len(moved) > 0 {
		addAdjustedTimers(pp, moved)
	}
}
```

### 2.6、运行计时器`runtimer`

会检查四叉堆堆顶的计时器，根据状态处理计时器

- `timerWaiting` -> `timerRunning`
- `timerDeleted` -> `timerRemoving` -> `timerRemoved`
- `timerModifiedXXX` -> `timerMoving` -> `timerWaiting`
- 其他状态 -> 等待或异常退出

1、状态是`timerDeleted`，状态变为`timerDeleted`，然后删除计时器，再变更状态为`timerRemoved`

```go
atomic.Cas(&t.status, s, timerRemoving)
dodeltimer0(pp)
atomic.Cas(&t.status, timerRemoving, timerRemoved)
```

2、状态是`timerModifiedXXX`

- 将计时器状态改成`timerMoving`
- 使用计时器下次触发时间`nextwhen`覆盖本次时间`when`
- 调用`dodeltimer0`删除堆顶的计时器
- 调用`doaddtimer`将计时器加入四叉堆中
- 将计时器状态改成`timerWaiting`

```go
atomic.Cas(&t.status, s, timerMoving)
t.when = t.nextwhen
dodeltimer0(pp)
doaddtimer(pp, t)
atomic.Cas(&t.status, timerMoving, timerWaiting)
```

3、状态是`timerWaiting`，如果计时器没有到达触发时间，直接返回，否则状态变为`timerRunning`，调用`runOneTimer`运行堆顶的计时器

```go
if t.when > now {
	// Not ready to run.
	return t.when
}
atomic.Cas(&t.status, s, timerRunning)
runOneTimer(pp, t, now)
```

```go
func runOneTimer(pp *p, t *timer, now int64) {
	f := t.f
	arg := t.arg
	seq := t.seq

	if t.period > 0 {
		delta := t.when - now
		t.when += t.period * (1 + -delta/t.period)
		siftdownTimer(pp.timers, 0)
		if !atomic.Cas(&t.status, timerRunning, timerWaiting) {
			badTimer()
		}
		updateTimer0When(pp)
	} else {
		dodeltimer0(pp)
		if !atomic.Cas(&t.status, timerRunning, timerNoStatus) {
			badTimer()
		}
	}

	unlock(&pp.timersLock)
	f(arg, seq)
	lock(&pp.timersLock)
}
```

根据`period`字段是否大于0判断，如果大于0

- 修改下一次的触发时间，并更新在四叉堆中的位置
- 更新状态`timerWaiting`
- 调用`updateTimer0When`设置下一个timer的触发时间

如果小于等于0：

- 移除定时器
- 更新状态`timerNoStatus`

更新完状态后，回调函数`f(arg, seq)`执行方法。

## 三、调度器

在`adjesttimers`中提到过

`checkTimers`是调度器用来运行处理器P中定时器的函数，会在以下几种情况被触发：

- 调度器调用`schedule`时
- 调度器在`findrunnable`获取可执行的G时
- 调度器在`findrunnable`从其他处理器偷G时

```go
func checkTimers(pp *p, now int64) (rnow, pollUntil int64, ran bool) {
	if atomic.Load(&pp.adjustTimers) == 0 {
		next := int64(atomic.Load64(&pp.timer0When))
		if next == 0 { 
			return now, 0, false
		}
		if now == 0 {
			now = nanotime()
		}
		if now < next {
			if pp != getg().m.p.ptr() || int(atomic.Load(&pp.deletedTimers)) <= int(atomic.Load(&pp.numTimers)/4) {
				return now, next, false
			}
		}
	}

	lock(&pp.timersLock)

	adjusttimers(pp)

	rnow = now
	if len(pp.timers) > 0 {
		if rnow == 0 {
			rnow = nanotime()
		}
		for len(pp.timers) > 0 {
			if tw := runtimer(pp, rnow); tw != 0 {
				if tw > 0 {
					pollUntil = tw
				}
				break
			}
			ran = true
		}
	}

	if pp == getg().m.p.ptr() && int(atomic.Load(&pp.deletedTimers)) > len(pp.timers)/4 {
		clearDeletedTimers(pp)
	}

	unlock(&pp.timersLock)

	return rnow, pollUntil, ran
}
```

1、先通过处理器P字段中`updateTimer0When`判断是否有需要执行的计时器，如果没有直接返回

2、如果下一个计时器没有到期但是需要删除的计时器较少时会直接返回

3、加锁

4、需要处理的timer，根据时间将timers切片中的timer重新排序，调用`adjusttimers`

5、会通过`runtimer`依次查找运行计时器

6、处理器中已删除的timer大于p上的timer数量的1/4，对标记为`timerDeleted`的timer进行清理

7、解锁

## 四、小结

go1.10最多可以创建`GOMAXPROCS`数量的timerproc协程，当然不超过64。但我们要知道timerproc自身就是协程，也需要runtime pmg的调度。到go 1.14把检查到期定时任务的工作交给了网络轮询器，不需要额外的调度，每次runtime.schedule和findrunable时直接运行到期的定时任务。

