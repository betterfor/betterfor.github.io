# 并发编程之条件变量Cond


`sync.Cond`字面意思就是同步条件变量，它实现的是一种监视器(`Monitor`)模式。

对于`Cond`而言，它实现一个条件变量，是goroutine间等待和通知的点。条件变量和共享的数据隔离，它可以同时阻塞多个goroutine，知道另外的goroutine更改了条件变量，并通知唤醒阻塞着的一个或多个goroutine。

## 演示例子

下面我们看一下 GopherCon 2018 上《Rethinking Classical Concurrency Patterns》 中的演示代码例子。

```go
type Item = int

type Queue struct {
	items     []Item
	itemAdded sync.Cond
}

func NewQueue() *Queue {
	q := new(Queue)
	q.itemAdded.L = &sync.Mutex{} // 为 Cond 绑定锁
	return q
}

func (q *Queue) Put(item Item) {
	q.itemAdded.L.Lock()
	defer q.itemAdded.L.Unlock()
	q.items = append(q.items, item)
	q.itemAdded.Signal() // 当 Queue 中加入数据成功，调用 Singal 发送通知
}

func (q *Queue) GetMany(n int) []Item {
	q.itemAdded.L.Lock()
	defer q.itemAdded.L.Unlock()
	for len(q.items) < n { // 等待 Queue 中有 n 个数据
		q.itemAdded.Wait() // 阻塞等待 Singal 发送通知
	}
	items := q.items[:n:n]
	q.items = q.items[n:]
	return items
}

func main() {
	q := NewQueue()

	var wg sync.WaitGroup
	for n := 10; n > 0; n-- {
		wg.Add(1)
		go func(n int) {
			items := q.GetMany(n)
			fmt.Printf("%2d: %2d\n", n, items)
			wg.Done()
		}(n)
	}

	for i := 0; i < 100; i++ {
		q.Put(i)
	}

	wg.Wait()
}
```

在这个例子中，`Queue`是存储`Item`的结构体，通过`Cond`类型的`itemAdded`来控制数据的输入与输出。可以看到，这里通过10个goroutine来消费数据，但是逐步添加100个数据至`Queue`中。最后，我们能够看到10个goroutine都能被唤醒，得到数据。

程序的运行结果如下：

```go
 3: [11 12 13]
 2: [ 0  1]
 9: [ 2  3  4  5  6  7  8  9 10]
 1: [14]
 6: [41 42 43 44 45 46]
 4: [32 33 34 35]
 5: [36 37 38 39 40]
 7: [25 26 27 28 29 30 31]
 8: [47 48 49 50 51 52 53 54]
10: [15 16 17 18 19 20 21 22 23 24]
```

当然，每次的运行结果都不会相同。

## 源码实现

`Cond`的实现还是比较简单的，代码量比较少，复杂的逻辑已经被`Locker`和`runtime`的等待队列实现了。

### 结构体

首先来看它的结构体：

```go
// A Cond must not be copied after first use.
type Cond struct {
	noCopy noCopy // 不允许拷贝

	// L is held while observing or changing the condition
	// L 是观察和改变条件的
	L Locker

	notify  notifyList  // 通知列表，调用Wait()方法的goroutine会放入list中，每次被唤醒从这里取出
	checker copyChecker // 拷贝检查，检查cond是否被拷贝
}
```

这里的`notifyList`通知列表：

```go
type notifyList struct {
	wait   uint32         // 写一个等待goroutine的ticket，是原子性的，在锁外递增
	notify uint32         // 下一个通知的goroutine的ticket，在锁外读取，但只能在持有锁的情况下写入
	lock   uintptr        // 需要传入的锁的标记
	head   unsafe.Pointer // 基于*sudog的双向链表的前驱指针
	tail   unsafe.Pointer // 基于*sudog的双向链表的后驱指针
}
```

基本结构大致就是这样，下面来看看实现方法。

### `Wait`方法的实现

```go
func (c *Cond) Wait() {
	c.checker.check()
	t := runtime_notifyListAdd(&c.notify) // 加入到通知列表
	c.L.Unlock()
	runtime_notifyListWait(&c.notify, t) // 等待通知
	c.L.Lock()
}
```

- 执行运行期间拷贝检查，如果发生了拷贝，则直接panic
- 调用`runtime_notifyListAdd`将等待计数器加1并解锁
- 调用`runtime_notifyListWait`等待其他`goroutine`的唤醒并加锁

而在`runtime/sema.go`中`runtime_notifyListAdd`的实现：

```go
func notifyListAdd(l *notifyList) uint32 {
	// This may be called concurrently, for example, when called from
	// sync.Cond.Wait while holding a RWMutex in read mode.
	return atomic.Xadd(&l.wait, 1) - 1
}
```

实现比较简单，就是原子操作将等待计数器+1，而返回的值是代表下一个等待唤醒的`goroutine`的索引

### `runtime_notifyListWait`的实现

```go
func notifyListWait(l *notifyList, t uint32) {
	lock(&l.lock)

	// Return right away if this ticket has already been notified.
	if less(t, l.notify) {
		unlock(&l.lock)
		return
	}

	// Enqueue itself.
	s := acquireSudog()
	s.g = getg()
	s.ticket = t
	s.releasetime = 0
	t0 := int64(0)
	if blockprofilerate > 0 {
		t0 = cputicks()
		s.releasetime = -1
	}
	if l.tail == nil {
		l.head = s
	} else {
		l.tail.next = s
	}
	l.tail = s
	goparkunlock(&l.lock, waitReasonSyncCondWait, traceEvGoBlockCond, 3)
	if t0 != 0 {
		blockevent(s.releasetime-t0, 2)
	}
	releaseSudog(s)
}
```

- 检查当前`wait`与`notify`索引位置是否匹配，如果已经通知过了，则立即返回
- 获取当前`goroutine`，并且将当前的`goroutine`加入到链表末端
- 调用`goparkunlock`方法挂起当前`goroutine`
- 被唤醒后，调用`releaseSudog`释放当前`goroutine`

`Signal`和`Boardcast`都会唤醒等待队列，不过`Signal`是唤醒链表最前面的`goroutine`，`Boardcast`会唤醒队列中全部的`goroutine`。

### Signal

```go
// 通知等待列表中的一个
func (c *Cond) Signal() {
	c.checker.check()
	runtime_notifyListNotifyOne(&c.notify)
}

func notifyListNotifyOne(l *notifyList) {
	// Fast-path: if there are no new waiters since the last notification
	// we don't need to acquire the lock at all.
	if atomic.Load(&l.wait) == atomic.Load(&l.notify) {
		return
	}

	lock(&l.lock)

	// Re-check under the lock if we need to do anything.
	t := l.notify
	if t == atomic.Load(&l.wait) {
		unlock(&l.lock)
		return
	}

	// Update the next notify ticket number.
	atomic.Store(&l.notify, t+1)

	for p, s := (*sudog)(nil), l.head; s != nil; p, s = s, s.next {
		if s.ticket == t {
			n := s.next
			if p != nil {
				p.next = n
			} else {
				l.head = n
			}
			if n == nil {
				l.tail = p
			}
			unlock(&l.lock)
			s.next = nil
			readyWithTime(s, 4)
			return
		}
	}
	unlock(&l.lock)
}
```

我们记得在`wait`代码中，每次调用都会原子累加`wait`，那么这个`wait`就代表最大的`wait`值，对应唤醒时，也会对应一个`notify`属性。我们在`notifyList`链表中逐个检查，找到`ticket`对应相等的`notify`属性。

`notifyList`并不是一直有序的，`wait`方法中调用`runtime_notifyListAdd`和`runtime_notifyListWait`完全是两个独立的行为。

### Broadcast

```go
// Broadcast唤醒所有等待的协程
func (c *Cond) Broadcast() {
	c.checker.check()
	runtime_notifyListNotifyAll(&c.notify)
}

func notifyListNotifyAll(l *notifyList) {
	// Fast-path: if there are no new waiters since the last notification
	// we don't need to acquire the lock.
	if atomic.Load(&l.wait) == atomic.Load(&l.notify) {
		return
	}

	// Pull the list out into a local variable, waiters will be readied
	// outside the lock.
	lock(&l.lock)
	s := l.head
	l.head = nil
	l.tail = nil

	// Update the next ticket to be notified. We can set it to the current
	// value of wait because any previous waiters are already in the list
	// or will notice that they have already been notified when trying to
	// add themselves to the list.
	atomic.Store(&l.notify, atomic.Load(&l.wait))
	unlock(&l.lock)

	// Go through the local list and ready all waiters.
	for s != nil {
		next := s.next
		s.next = nil
		readyWithTime(s, 4)
		s = next
	}
}
```

全部唤醒的实现简单一点，主要是通过调用`readyWithTime`方法唤醒链表中的goroutine，唤醒的顺序也是按照加入队列的先后顺序唤醒，而后加入的goroutine可能需要等待调度器的调度。

## 使用场景

每次向队列中添加元素后就需要调用`Broadcast`通知所有的等待者，使用`Cond`很合适，相比`channel`减少了代码的复杂度。

当然使用的姿势一定要正确：

```go
 c.L.Lock()
for !condition() {
   c.Wait()
}
// ... make use of condition ...
c.L.Unlock()
```


