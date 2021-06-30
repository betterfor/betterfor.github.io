# 高并发系统下的限速策略


限流又称为流量控制，是限制到达系统的并发请求数，当达到限制条件时可以拒绝请求，可以起到保护下游服务，熔断流量的作用。常用的限流策略有漏桶算法、令牌桶算法、滑动窗口。

## 限流算法

### 计数器算法

计数器算法是限流算法中最简单也是最容易实现的一种算法。设置某段时间内的计数器是一个定值，当请求值在范围内则放行，如果超过计数器则限流。

```go
var (
	once sync.Once
	ErrExceededLimit = errors.New("Too many requests, exceed the limit. ")
)

type fixedWindowCounter struct {
	duration time.Duration
	currentRequests, allowRequests int32
}

func New(duration time.Duration, allowRequests int32) *fixedWindowCounter {
	return &fixedWindowCounter{duration: duration, allowRequests: allowRequests}
}

func (c *fixedWindowCounter) Take() error {
	once.Do(func() {
		go func() {
			for  {
				select {
				case <-time.After(c.duration):
					atomic.StoreInt32(&c.currentRequests, 0)
				}
			}
		}()
	})

	curRequest := atomic.LoadInt32(&c.currentRequests)
	if curRequest >= c.allowRequests {
		return ErrExceededLimit
	}
	if !atomic.CompareAndSwapInt32(&c.currentRequests, curRequest, curRequest+1) {
		return ErrExceededLimit
	}
	return nil
}
```

### 滑动窗口

计数器算法虽然简单，但是会有临界问题，如果有恶意请求在时间边界处大量请求，这会导致瞬间的请求量变大。

所以引入滑动窗口，例如把1分钟化成6格，每格就是10秒，每过10秒，滑动窗口就会向右滑动一格，每个格子都有自己的计数器。

由此可见，当滑动窗口的格子划分的越多，那么滑动窗口的滚动就越平滑，限流的统计就会越精确。

```go
var (
	once sync.Once
	ErrExceededLimit = errors.New("Too many requests, exceed the limit. ")
)

type slidingWindowCounter struct {
	total, slot time.Duration
	durationRequests chan int32
	inDurRequests int32
	currentRequests, allowRequests int32
}

func New(slot, total time.Duration, allowRequests int32) *slidingWindowCounter {
	return &slidingWindowCounter{durationRequests: make(chan int32, total/slot/1000), total: total, slot: slot, allowRequests: allowRequests}
}

func (c *slidingWindowCounter) Take() error {
	once.Do(func() {
		go func() {
			go sliding(c)
			go calculate(c)
		}()
	})

	curRequest := atomic.LoadInt32(&c.currentRequests)
	if curRequest >= c.allowRequests {
		return ErrExceededLimit
	}
	if !atomic.CompareAndSwapInt32(&c.currentRequests, curRequest, curRequest+1) {
		return ErrExceededLimit
	}
	atomic.AddInt32(&c.inDurRequests,1)
	return nil
}

func sliding(c *slidingWindowCounter) {
	for  {
		select {
		case <-time.After(c.slot):
			t := atomic.SwapInt32(&c.inDurRequests, 0)
			c.durationRequests <- t
		}
	}
}

func calculate(c *slidingWindowCounter) {
	// 通道加满
	for  {
		<-time.After(c.slot)
		if len(c.durationRequests) == cap(c.durationRequests) {
			break
		}
	}
	// 定时从通道中取出数据，对currentRequests置0
	for  {
		<-time.After(c.slot)
		t := <- c.durationRequests
		if t != 0 {
			atomic.AddInt32(&c.currentRequests, -t)
		}
	}
}
```

### 漏桶算法

水（请求）先到漏桶中，漏桶以一定速率出水，当水的流入速度过大时会直接溢出，可以看出漏桶算法能强行限制数据的传输速率。

```go
var (
	once sync.Once
	ErrExceededLimit = errors.New("Too many requests, exceed the limit. ")
)

type leakyBucket struct {
	duration time.Duration
	bucketSize chan struct{}
	allowRequests int32
}

func New(duration time.Duration, bucketSize, allowRequests int32) *leakyBucket {
	return &leakyBucket{duration: duration, bucketSize: make(chan struct{}, allowRequests/bucketSize), allowRequests: allowRequests}
}

func (c *leakyBucket) Take() error {
	once.Do(func() {
		go func() {
			for  {
				select {
				case <-time.After(time.Duration(c.duration.Nanoseconds()/int64(c.allowRequests))):
					c.bucketSize <- struct{}{}
				}
			}
		}()
	})
	select {
	case <-c.bucketSize:
		return nil
	default:
	}
	return ErrExceededLimit
}
```

### 令牌桶算法

[令牌桶](https://en.wikipedia.org/wiki/Token_bucket)是一种常见于用于控制速率的控流算法。系统会以一个恒定的速度往桶里放入令牌，而如果请求需要被处理，则需要先从桶里获取一个令牌，当桶里没有令牌可取时，则拒绝服务。

```go
var (
	once sync.Once
	ErrExceededLimit = errors.New("Too many requests, exceed the limit. ")
)

type leakyBucket struct {
	duration      time.Duration
	token         chan struct{}
	allowRequests int32
}

func New(duration time.Duration, allowRequests int32) *leakyBucket {
	return &leakyBucket{duration: duration, token: make(chan struct{}, allowRequests), allowRequests: allowRequests}
}

func (c *leakyBucket) Take() error {
	once.Do(func() {
		go func() {
			for  {
				select {
				case <-time.After(time.Duration(c.duration.Nanoseconds()/int64(c.allowRequests))):
					c.token <- struct{}{}
				}
			}
		}()
	})
	select {
	case <-c.token:
		return nil
	default:
	}
	return ErrExceededLimit
}
```

### 小结

计数器算法优点是简单，能够满足简单的限流需求，缺点是临界问题，流量曲线可能不够平滑，会有“突刺现象”，在窗口切换时可能会产生两倍于阈值的流量请求。

滑动窗口算法作为对计数器算法的改进，能有效解决窗口切换时可能会产生两倍于阈值的流量请求的问题。

漏桶算法的出水速度是恒定的，那么瞬时大流量，将有大部分请求会被丢弃。

令牌桶算法生成的令牌速度是恒定的，而请求去拿令牌桶是没有速度限制的，这意味着面对瞬时流量，可以短时间内拿到大量令牌。

## 限流源码

### [golang.org/x/time/rate](https://github.com/golang/time)

是一个令牌桶算法。

Limiter有三个主要的方法 Allow、Reserve和Wait，最常用的是Wait和Allow方法

 

这三个方法每调用一次都会消耗一个令牌，这三个方法的区别在于没有令牌时，他们的处理方式不同

Allow： 如果没有令牌，则直接返回false

Reserve：如果没有令牌，则返回一个reservation，

Wait：如果没有令牌，则等待直到获取一个令牌或者其上下文被取消。

 

tokens更新的策略：

1、 成功获取到令牌或成功预约(Reserve)到令牌

2、预约取消时(Cancel)并且需要还原令牌到令牌桶中时

3、重新设置限流器的速率时(SetLimit)

4、重新设置限流器的容量时(SetBurst)

#### Limit类型

```go
// Limit 就是float64的别名，定义事件的最大频率，表示每秒发生的事件数。0表示无限制。
type Limit float64

// Inf 是无限速率限制允许所有事件(即使突发为0)
const Inf = Limit(math.MaxFloat64)

// Every 指定向Token桶中防止token的间隔，计算出每秒的数据量
func Every(interval time.Duration) Limit {
	if interval <= 0 {
		return Inf
	}
	return 1 / Limit(interval.Seconds())
}
```

#### Limiter结构体

```go
// The methods AllowN, ReserveN, and WaitN consume n tokens.
type Limiter struct {
	mu     sync.Mutex
	limit  Limit
	burst  int	// 令牌桶的最大数量，如果burst=0且limit=Inf，则允许处理任何事件
	tokens float64	// 可用令牌数
	last time.Time	// 记录上次limiter的tokens被更新的时间
	lastEvent time.Time // 记录速率受限的时间点（过去时间点或未来时间点）
}
```

#### Revervation结构体

```go
// Reservation 预定令牌的操作，timeToAct 是本次预约需要等待到的指定时间点才有足够预约的令牌。
type Reservation struct {
	ok        bool	// 到截止时间是否能够获取足够的令牌
	lim       *Limiter
	tokens    int	// 需要获取的令牌数
	timeToAct time.Time	// 需要等待的时间点
	limit Limit	// 代表预定的时间，可以被更改
}
```

#### Limiter消费token

`Limiter`有3个消费`token`的方法，分别是`Allow`/`Reverse`/`Wait`，最终这些方法调用`reserveN`和`advance`来实现。

- `advance`的实现

```go
// advance 更新令牌桶的状态，计算出令牌桶未更新的时间，然后计算出需要向令牌桶中添加的令牌数
func (lim *Limiter) advance(now time.Time) (newNow time.Time, newLast time.Time, newTokens float64) {
	// last不能在now之后，否则计算出来的elapsed为负数，会导致令牌桶数量减少
	last := lim.last
	if now.Before(last) {
		last = now
	}

	// 根据令牌桶的余数计算出令牌桶未进行更新的最大时间
	maxElapsed := lim.limit.durationFromTokens(float64(lim.burst) - lim.tokens)
	elapsed := now.Sub(last)
	if elapsed > maxElapsed {
		elapsed = maxElapsed
	}

	// 根据未更新的时间（未向桶中加入令牌的时间段）计算出产生的令牌数
	delta := lim.limit.tokensFromDuration(elapsed)
	tokens := lim.tokens + delta
	if burst := float64(lim.burst); tokens > burst {
		tokens = burst
	}

	return now, last, tokens
}
```

- `reverseN`的实现

```go
// reserveN is a helper method for AllowN, ReserveN, and WaitN.
// reserveN 判断在maxFutureReserve时间内是否有足够的令牌
func (lim *Limiter) reserveN(now time.Time, n int, maxFutureReserve time.Duration) Reservation {
	lim.mu.Lock()

	if lim.limit == Inf {
		lim.mu.Unlock()
		return Reservation{
			ok:        true, // 桶中有足够的令牌
			lim:       lim,
			tokens:    n,
			timeToAct: now,
		}
	}

	// 更新桶的状态，tokens为桶可用的令牌数
	now, last, tokens := lim.advance(now)

	// 计算取完后桶中剩下的令牌数
	tokens -= float64(n)

	// 如果tokens<0，说明tokens不够，计算需要等待的时间
	var waitDuration time.Duration
	if tokens < 0 {
		waitDuration = lim.limit.durationFromTokens(-tokens)
	}

	ok := n <= lim.burst && waitDuration <= maxFutureReserve

	// Prepare reservation
	r := Reservation{
		ok:    ok,
		lim:   lim,
		limit: lim.limit,
	}
	if ok {
		r.tokens = n
		r.timeToAct = now.Add(waitDuration)
	}

	// 更新桶中的token，时间，lastEvent
	if ok {
		lim.last = now
		lim.tokens = tokens
		lim.lastEvent = r.timeToAct
	} else {
		lim.last = last
	}

	lim.mu.Unlock()
	return r
}
```

这上面提到了`durationFromTokens`和`tokensFromDuration`两种方法。

```go
// durationFromTokens 限制令牌所花费的时间
func (limit Limit) durationFromTokens(tokens float64) time.Duration {
	seconds := tokens / float64(limit)
	return time.Nanosecond * time.Duration(1e9*seconds) // 1s * seconds
}

// tokensFromDuration 根据时间可以产生的令牌数
func (limit Limit) tokensFromDuration(d time.Duration) float64 {
	// Split the integer and fractional parts ourself to minimize rounding errors.
	// See golang.org/issues/34861.
	// 之前的版本如下
	// return d.Seconds() * float64(limit)
	// 这里的d.Seconds()已经是小数了，两个小数相乘会带来精度的缺失。
	sec := float64(d/time.Second) * float64(limit)
	nsec := float64(d%time.Second) * float64(limit)
	return sec + nsec/1e9
}
```

#### Limiter归还token

```go
func (r *Reservation) CancelAt(now time.Time) {
	if !r.ok {
		return
	}

	r.lim.mu.Lock()
	defer r.lim.mu.Unlock()

	// 如果无需限流或tokens为0或过了截止时间，无需处理取消操作
	if r.lim.limit == Inf || r.tokens == 0 || r.timeToAct.Before(now) {
		return
	}

	// 计算需要还原的令牌数量
	restoreTokens := float64(r.tokens) - r.limit.tokensFromDuration(r.lim.lastEvent.Sub(r.timeToAct))
	if restoreTokens <= 0 {
		return
	}
	// 重新计算令牌桶的状态
	now, _, tokens := r.lim.advance(now)
	// 还原当前令牌桶的令牌数量，当前的令牌数tokens加上需要还原的令牌数restoreTokens
	tokens += restoreTokens
	if burst := float64(r.lim.burst); tokens > burst {
		tokens = burst
	}
	// update state
	r.lim.last = now
	r.lim.tokens = tokens
	// 如果相等，说明和没有消费一样，直接还原成上次的状态
	if r.timeToAct == r.lim.lastEvent {
		prevEvent := r.timeToAct.Add(r.limit.durationFromTokens(float64(-r.tokens)))
		if !prevEvent.Before(now) {
			r.lim.lastEvent = prevEvent
		}
	}
}
```

#### 小结

![](高并发系统下的限速策略.assets/time_rate_limiter.jpg)

> 按照图示，令牌桶的实现似乎是这样的：有一个定时器Timer和队列Queue，Timer定时向Queue放token，用户从Queue取token。

这固然是Token Bucket的一种实现方式，这么做也非常直观，但是效率太低了：我们需要不仅多维护一个Timer和BlockingQueue，而且还耗费了一些不必要的内存。

在Golang的`timer/rate`中的实现, 并没有单独维护一个Timer，而是采用了lazyload的方式，直到每次消费之前才根据时间差更新Token数目，而且也不是用BlockingQueue来存放Token，而是仅仅通过计数的方式。

`NewLimiter`的第一个参数是速率limit，代表了一秒钟可以产生多少Token。
那么简单换算一下，我们就可以知道一个Token的生成间隔是多少。

有了这个生成间隔，我们就可以轻易地得到两个数据：
**1. 生成N个新的Token一共需要多久。**time/rate中对应的实现函数 durationFromTokens。
**2. 给定一段时长，这段时间一共可以生成多少个Token。**time/rate中对应的实现函数为tokensFromDuration。

那么，有了这些转换函数，整个过程就很清晰了，如下：

1. 计算从上次取Token的时间到当前时刻，期间一共新产生了多少Token：我们只在取Token之前生成新的Token，也就意味着每次取Token的间隔，实际上也是生成Token的间隔。我们可以利用tokensFromDuration, 轻易的算出这段时间一共产生Token的数目。
   那么，当前Token数目 = 新产生的Token数目 + 之前剩余的Token数目 - 要消费的Token数目。

2. 如果消费后剩余Token数目大于零，说明此时Token桶内仍不为空，此时Token充足，无需调用侧等待。
   如果Token数目小于零，则需等待一段时间。
   那么这个时候，我们可以利用durationFromTokens将当前负值的Token数转化为需要等待的时间。

3. 将需要等待的时间等相关结果返回给调用方。

从上面可以看出，其实整个过程就是利用了**Token数可以和时间相互转化**的原理。 而如果Token数为负，则需要等待相关时间即可。

### [uber-go/ratelimit](https://github.com/uber-go/ratelimit)

基于漏桶实现。

#### 例子

```go
	rl := ratelimit.New(100) // per second

    prev := time.Now()
    for i := 0; i < 10; i++ {
        now := rl.Take()
        fmt.Println(i, now.Sub(prev))
        prev = now
    }
    // Output:
    // 0 0
    // 1 10ms
    // 2 10ms
    // 3 10ms
    // 4 10ms
    // 5 10ms
    // 6 10ms
    // 7 10ms
    // 8 10ms
    // 9 10ms
```

#### 基本实现

要实现上面的每秒固定速率，很简单。

在`ratelimit`的`New`函数中，传入的参数是每秒允许请求量(Requests Per Second)。

我们就能很轻松计算出每个请求的时间间隔：

```go
perRequest := time.Second / time.Duration(rate)
```

如图，当请求1处理结束后，记录请求1的处理完成时间，记为`limiter.last`。请求2到达时，如果此时的时间与`limiter.last`的时间间隔小于`preRequest`，那么`sleep`一段时间。

![](高并发系统下的限速策略.assets/wait-interval.png)

```go
sleepFor = t.PreRequest - now.Sub(t.last)
if sleepFor > 0 {
    t.clock.Sleep(sleepFor)
    t.last = now.Add(sleepFor)
} else {
    t.last = now
}
```



然而，在现实请求中，流量经常是突发的，有些请求间隔比较长，有些请求间隔比较短。

![](高并发系统下的限速策略.assets/3-requests.png)

所以uber引入最大松弛量，把之前间隔比较长的请求时间，匀给后面的使用。

![](高并发系统下的限速策略.assets/maxslack.png)

而实现起来也很简单，就是把每个请求多出的等待时间累加起来，给后面的请求冲抵。

```go
t.sleepFor += t.preReqeust - now.Sub(t.last)
if t.sleepFor < t.maxSlack {
    t.sleepFor = t.maxSlack
}
if t.sleepFor > 0 {
    t.clock.Sleep(t.sleepFor)
    t.last = now.Add(t.sleepFor)
    t.sleepFor = 0
} else {
    t.last = now
}
```

源码解析：

```go
func New(rate int, opts ...Option) Limiter {
	return newAtomicBased(rate, opts...)
}

// buildConfig combines defaults with options.
func buildConfig(opts []Option) config {
	c := config{
		clock: clock.New(),
		slack: 10,
		per:   time.Second,
	}

	for _, opt := range opts {
		opt.apply(&c)
	}
	return c
}

func newAtomicBased(rate int, opts ...Option) *atomicLimiter {
	config := buildConfig(opts)
	// 两个请求的最小时间间隔
	perRequest := config.per / time.Duration(rate)
	l := &atomicLimiter{
		perRequest: perRequest,
		maxSlack:   -1 * time.Duration(config.slack) * perRequest, // 最大松弛量
		clock:      config.clock,
	}

	initialState := state{
		last:     time.Time{},
		sleepFor: 0,
	}
	atomic.StorePointer(&l.state, unsafe.Pointer(&initialState))
	return l
}
```



```go
func (t *atomicLimiter) Take() time.Time {
	var (
		newState state
		taken    bool
		interval time.Duration
	)
	for !taken {
		now := t.clock.Now()

		previousStatePointer := atomic.LoadPointer(&t.state)
		oldState := (*state)(previousStatePointer)

		newState = state{
			last:     now,
			sleepFor: oldState.sleepFor,
		}

		// 如果是第一次请求，更新状态
		if oldState.last.IsZero() {
			taken = atomic.CompareAndSwapPointer(&t.state, previousStatePointer, unsafe.Pointer(&newState))
			continue
		}

		newState.sleepFor += t.perRequest - now.Sub(oldState.last)
		// 例如请求1完成后，请求2在几个小时后到达，那么对于now.Sub(oldState.last)会非常大，而这里newState.sleepFor表示允许冲抵的最长时间。
		if newState.sleepFor < t.maxSlack { // t.maxSlack默认10个请求的间隔大小
			newState.sleepFor = t.maxSlack
		}
		if newState.sleepFor > 0 {
			// 代表此前的请求多余出的时间，无法完全冲抵此次所需量
			newState.last = newState.last.Add(newState.sleepFor)
			interval, newState.sleepFor = newState.sleepFor, 0
		}
		taken = atomic.CompareAndSwapPointer(&t.state, previousStatePointer, unsafe.Pointer(&newState))
	}
	t.clock.Sleep(interval)
	return newState.last
}
```


