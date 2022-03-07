---
title: "client-go之工作队列"
date: 2022-03-07T13:32:36+08:00
draft: false

tags: ['kubernetes','client-go']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

workqueue是client-go的工作队列，主要用于并行程序控制，比如各种资源`controller`监听`informer`对象的变化，当有变化时通过回调函数写入队列，再由其他协程处理。

那么为什么不直接使用goroutine+channel呢？这是因为goroutine+channel组成的功能单一，没有办法满足场景，比如限流。

## 一、接口定义

```go
type Interface interface {
	Add(item interface{})
	Len() int
	Get() (item interface{}, shutdown bool)
	Done(item interface{})
	ShutDown()
	ShutDownWithDrain()
	ShuttingDown() bool
}
```

看类型的话，这个队列的功能也很简单，就是向队列中增删改查。

## 二、工作队列

```go
type Type struct {
	queue []t
	dirty set
	processing set
	cond *sync.Cond
	shuttingDown bool
	drain        bool
	metrics queueMetrics
	unfinishedWorkUpdatePeriod time.Duration
	clock                      clock.WithTicker
}

type empty struct{}
type t interface{}
type set map[t]empty
```

- queue就是队列元素
- dirty和process放的是元素集合

只看类型，看不出具体内容，需要结合实际方法

```go
func (q *Type) Add(item interface{}) {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()
	// 队列已关闭，直接返回
	if q.shuttingDown {
		return
	}
	// dirty中存在数据，直接返回
	if q.dirty.has(item) {
		return
	}

	q.metrics.add(item)

	// 元素添加到dirty中
	q.dirty.insert(item)
	// 元素已经在处理中，就直接返回
	if q.processing.has(item) {
		return
	}

	// 追加到元素队列中
	q.queue = append(q.queue, item)
	q.cond.Signal()
}
```

```go
func (q *Type) Get() (item interface{}, shutdown bool) {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()
	// 没有数据，阻塞协程
	for len(q.queue) == 0 && !q.shuttingDown {
		q.cond.Wait()
	}
	if len(q.queue) == 0 {
		// We must be shutting down.
		return nil, true
	}

	// 取出队首元素
	item = q.queue[0]
	// The underlying array still exists and reference this object, so the object will not be garbage collected.
	q.queue[0] = nil
	q.queue = q.queue[1:]

	q.metrics.get(item)

	// 插入到进行中，删除脏数据
	q.processing.insert(item)
	q.dirty.delete(item)

	return item, false
}
```

```go
func (q *Type) Done(item interface{}) {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()

	q.metrics.done(item)

	// 删除进行中的元素
	q.processing.delete(item)
	// 如果dirty中存在，重新加入队列
	if q.dirty.has(item) {
		q.queue = append(q.queue, item)
		q.cond.Signal()
	} else if q.processing.len() == 0 {
		q.cond.Signal()
	}
}
```

队列添加元素有几种状态流转：

- 队列关闭了，不接受数据
- 队列中没有该元素，直接存储在队列中
- 队列中存储有该元素，但是被拿走但是没有`Done`，也就是正在处理的元素，认为是脏数据，不入队列。
- 当处理完元素，也就是`Done`，如果在`dirty`中发现该元素，重新加入到队列中。

## 三、延迟队列

延迟队列就是在某个时间后才将元素添加进通用队列。比如希望在1分钟后删除pod，这时就需要维护一个全局的延迟队列，来缓慢处理元素。

延迟队列的抽象格式如下

```go
type DelayingInterface interface {
	Interface
	AddAfter(item interface{}, duration time.Duration)
}
```

继承了通用队列的所有接口，增加了延迟添加的方法。

从实现类型也能够看出

```go
type delayingType struct {
	Interface
	clock clock.Clock
	stopCh chan struct{}
	stopOnce sync.Once
	heartbeat clock.Ticker
	waitingForAddCh chan *waitFor
	metrics retryMetrics
}

type waitFor struct {
	data    t
	readyAt time.Time
	index int	// 在堆中索引
}
```

和通用队列比较起来，实现的类型大不相同。

通用队列的实现是通过脏数据来实现数据集合，而延迟队列是通过实现堆来实现数据集合。

```go
type waitForPriorityQueue []*waitFor

func (pq waitForPriorityQueue) Len() int {
   return len(pq)
}
func (pq waitForPriorityQueue) Less(i, j int) bool {
   return pq[i].readyAt.Before(pq[j].readyAt)
}
func (pq waitForPriorityQueue) Swap(i, j int) {
   pq[i], pq[j] = pq[j], pq[i]
   pq[i].index = i
   pq[j].index = j
}

func (pq *waitForPriorityQueue) Push(x interface{}) {
   n := len(*pq)
   item := x.(*waitFor)
   item.index = n
   *pq = append(*pq, item)
}

func (pq *waitForPriorityQueue) Pop() interface{} {
   n := len(*pq)
   item := (*pq)[n-1]
   item.index = -1
   *pq = (*pq)[0:(n - 1)]
   return item
}
```

这个就是`heap`的实现，使用`waitForPriorityQueue`管理所有延迟添加的元素，按照时间大小排序。

```go
func (q *delayingType) AddAfter(item interface{}, duration time.Duration) {
	if q.ShuttingDown() {
		return
	}

	if duration <= 0 {
		q.Add(item)
		return
	}

	select {
	case <-q.stopCh:
	case q.waitingForAddCh <- &waitFor{data: item, readyAt: q.clock.Now().Add(duration)}:
	}
}
```

`AddAfter`方法是向`waitingForAddCh`传入数据，在初始化的时候是从`chan`中读取数据

```go
func newDelayingQueue(clock clock.WithTicker, q Interface, name string) *delayingType {
	ret := &delayingType{
		Interface:       q,
		clock:           clock,
		heartbeat:       clock.NewTicker(maxWait),
		stopCh:          make(chan struct{}),
		waitingForAddCh: make(chan *waitFor, 1000),
		metrics:         newRetryMetrics(name),
	}

	go ret.waitingLoop()
	return ret
}
```

而`waitingForAddCh`中的实现，其实就是先将元素加入到有序队列中，然后判断是否到达时间，如果到达了时间，将元素通过`Add`方法添加进去。

## 四、限速队列

比如在操作失败后，希望能够重试几次，而立即重试可能还会失败，那么就希望能够延迟一段时间重试，重试次数越多延迟时间越长。

限速队列的抽象接口：

```go
type RateLimiter interface {
    // 返回元素需要等待多长时间
	When(item interface{}) time.Duration
    // 丢弃改元素
	Forget(item interface{})
    // 元素放入队列的次数
	NumRequeues(item interface{}) int
}
```

### 4.1、BucketRateLimiter

```go
type BucketRateLimiter struct {
	*rate.Limiter
}

var _ RateLimiter = &BucketRateLimiter{}

func (r *BucketRateLimiter) When(item interface{}) time.Duration {
	return r.Limiter.Reserve().Delay()
}
```

利用`golang.org/x/time/rate`的`rate.Limiter`实现固定限速器

### 4.2、ItemExponentialFailureRateLimiter

常用的限速器，根据元素错误次数累加时间

```go
type ItemExponentialFailureRateLimiter struct {
	failuresLock sync.Mutex
	failures     map[interface{}]int

	baseDelay time.Duration
	maxDelay  time.Duration
}

func (r *ItemExponentialFailureRateLimiter) When(item interface{}) time.Duration {
	r.failuresLock.Lock()
	defer r.failuresLock.Unlock()

	exp := r.failures[item]
	r.failures[item] = r.failures[item] + 1

	// The backoff is capped such that 'calculated' value never overflows.
	backoff := float64(r.baseDelay.Nanoseconds()) * math.Pow(2, float64(exp))
	if backoff > math.MaxInt64 {
		return r.maxDelay
	}

	calculated := time.Duration(backoff)
	if calculated > r.maxDelay {
		return r.maxDelay
	}

	return calculated
}
```

实现的话也不是特别难，用个map装载元素，元素失败后累加元素的延迟时间，根据`2^i * baseDelay`计算延迟时间，按指数递增。

### 4.3、ItemFastSlowRateLimiter

和`ItemExponentialFailureRateLimiter`很像，但是`ItemFastSlowRateLimiter`策略是根据次数来限制，如果超过次数使用长延迟，否则用短延迟

```go
type ItemFastSlowRateLimiter struct {
	failuresLock sync.Mutex
	failures     map[interface{}]int

	maxFastAttempts int
	fastDelay       time.Duration
	slowDelay       time.Duration
}

func (r *ItemFastSlowRateLimiter) When(item interface{}) time.Duration {
	r.failuresLock.Lock()
	defer r.failuresLock.Unlock()

	r.failures[item] = r.failures[item] + 1

	if r.failures[item] <= r.maxFastAttempts {
		return r.fastDelay
	}

	return r.slowDelay
}
```

### 4.4、MaxOfRateLimiter

内部有多个限速器，每次返回最悲观的，意思就是每次返回延迟时间最长的。

```go
type MaxOfRateLimiter struct {
	limiters []RateLimiter
}

func (r *MaxOfRateLimiter) When(item interface{}) time.Duration {
	ret := time.Duration(0)
	for _, limiter := range r.limiters {
		curr := limiter.When(item)
		if curr > ret {
			ret = curr
		}
	}

	return ret
}
```

---

之后就是限速队列的实现了

```go
type RateLimitingInterface interface {
	DelayingInterface
	AddRateLimited(item interface{})
	Forget(item interface{})
	NumRequeues(item interface{}) int
}

type rateLimitingType struct {
	DelayingInterface

	rateLimiter RateLimiter
}
```

了解了限速器，理解限速队列就很容易了。

```go
func (q *rateLimitingType) AddRateLimited(item interface{}) {
	q.DelayingInterface.AddAfter(item, q.rateLimiter.When(item))
}

func (q *rateLimitingType) NumRequeues(item interface{}) int {
	return q.rateLimiter.NumRequeues(item)
}

func (q *rateLimitingType) Forget(item interface{}) {
	q.rateLimiter.Forget(item)
}
```

通过限速器获取元素的延迟时间，然后通过延迟队列添加元素，这样队列的元素就会按照一定的速率进入了。

## 五、总结

`workqueue`工作队列主要的实现还是通用队列，用`dirty`的概念减少重复添加元素。

延迟队列和限速队列都是通用队列的扩展。

