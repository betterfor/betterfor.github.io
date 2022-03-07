---
title: "Context控制goroutine并发运行"
date: 2022-03-07T11:12:38+08:00
draft: false

tags: ['context']
categories: ["月霜天的小随笔"]
comment: true
toc: true
autoCollapseToc: false
---

在并发程序中，由于超时、取消操作或其他一些异常情况，往往需要通知其他goroutine，虽然可以使用channel来处理这些问题，但是会变得非常繁琐，而且不利于多级管理。

go使用Context来做解决方案。

## 1、Context接口

```go
type Context interface {
    Deadline() (deadline time.Time, ok bool)
    Done() <-chan struct{}
    Err() error
    Value(key interface{}) interface{}
}
```

Context接口包含4个方法

- `Deadline`：返回绑定当前Context的任务被取消的截止时间，如果没有设置时间，`ok=false`
- `Done`：context任务被取消，返回一个信号`struct{}`，如果不被取消，返回nil
- Err：如果Done已经关闭，将返回非空的值表明任务结束的原因
- Value：存储的键值对中当前key对应的值

## 2、emptyCtx

`emptyCtx`其实就是一个`int`类型的变量，实现了Context接口。

如其名，就是一个没有设置超时时间，不能取消，也不能存储键值对的Context。

`emptyCtx`用来作为context的根结点。

```go
type emptyCtx int

func (*emptyCtx) Deadline() (deadline time.Time, ok bool) {
	return
}

func (*emptyCtx) Done() <-chan struct{} {
	return nil
}

func (*emptyCtx) Err() error {
	return nil
}

func (*emptyCtx) Value(key interface{}) interface{} {
	return nil
}
```

而我们通常不会直接使用`emptyCtx`，而是使用`emptyCtx`实例化的两个变量

```go
var (
	background = new(emptyCtx)
	todo       = new(emptyCtx)
)

func Background() Context {
	return background
}

func TODO() Context {
	return todo
}
```

- `Background`：通常被用作主函数，初始化以及测试中，作为顶级的context
- `TODO`：不确定使用什么context时

## 3、valueCtx

### 3.1、基础类型

```go
type valueCtx struct {
	Context
	key, val interface{}
}

func (c *valueCtx) Value(key interface{}) interface{} {
    if c.key == key {
        return c.val
    }
    return c.Context.Value(key)
}
```

`valueCtx`利用了context类型的变量来表示父节点context，继承了父context的所有信息。

`valueCtx`携带了一个键值对，实现了`Value`方法，所以可以在context上获取key对应的值，如果context不存在，会沿着父context向上查找

### 3.2、实现方法

```go
func WithValue(parent Context, key, val interface{}) Context {
	if key == nil {
		panic("nil key")
	}
	if !reflectlite.TypeOf(key).Comparable() {
		panic("key is not comparable")
	}
	return &valueCtx{parent, key, val}
}
```

向context中添加键值对，并不是直接在原context上直接添加，而是创建一个新的`valueCtx`，将键值对添加在子节点上。

## 4、cancelCtx

### 4.1、基础类型

```go
type canceler interface {
    cancel(removeFromParent bool, err error)
    Done() <-chan struct{}
}
type cancelCtx struct {
	Context

	mu       sync.Mutex            
	done     chan struct{}         
	children map[canceler]struct{}
	err      error                
}
```

和`valueCtx`类似，也有父context，

- 通道`done`用来传递关闭信号。
- `children`存储了context节点下的子节点，
- err用于存储取消原因

```go
func (c *cancelCtx) Value(key interface{}) interface{} {
	if key == &cancelCtxKey {
		return c
	}
	return c.Context.Value(key)
}

func (c *cancelCtx) Done() <-chan struct{} {
	c.mu.Lock()
	if c.done == nil {
		c.done = make(chan struct{})
	}
	d := c.done
	c.mu.Unlock()
	return d
}

func (c *cancelCtx) Err() error {
	c.mu.Lock()
	err := c.err
	c.mu.Unlock()
	return err
}
```

### 4.2、实现方法

```go
func WithCancel(parent Context) (ctx Context, cancel CancelFunc) {
	c := newCancelCtx(parent)
	propagateCancel(parent, &c)
	return &c, func() { c.cancel(true, Canceled) }
}
```

`newCancelCtx`只是初始化了`cancelCtx`

```go
func newCancelCtx(parent Context) cancelCtx {
	return cancelCtx{Context: parent}
}
```

`propagateCancel`建立当前节点与父节点的取消逻辑

```go
func propagateCancel(parent Context, child canceler) {
	done := parent.Done()
	if done == nil {
		return
	}

	select {
	case <-done:
		child.cancel(false, parent.Err())
		return
	default:
	}

	if p, ok := parentCancelCtx(parent); ok {
		p.mu.Lock()
		if p.err != nil {
			child.cancel(false, p.err)
		} else {
			if p.children == nil {
				p.children = make(map[canceler]struct{})
			}
			p.children[child] = struct{}{}
		}
		p.mu.Unlock()
	} else {
		atomic.AddInt32(&goroutines, +1)
		go func() {
			select {
			case <-parent.Done():
				child.cancel(false, parent.Err())
			case <-child.Done():
			}
		}()
	}
}
```

1、如果父context已经取消了，就直接返回，因为父节点不可能再被取消了

2、监听信号`done`，如果接收到了就通知子context取消

3、如果找到父context，就挂在父context上

4、如果没有找到父context，也就是自身是根context，就启动一个goroutine监听信号

而调用的`cancel`方法，其实就是关闭通道及设置原因

```go
func (c *cancelCtx) cancel(removeFromParent bool, err error) {
	if err == nil {
		panic("context: internal error: missing cancel error")
	}
	c.mu.Lock()
	if c.err != nil {
		c.mu.Unlock()
		return // already canceled
	}
	c.err = err
	if c.done == nil {
		c.done = closedchan
	} else {
		close(c.done)
	}
	for child := range c.children {
		child.cancel(false, err)
	}
	c.children = nil
	c.mu.Unlock()

	if removeFromParent {
		removeChild(c.Context, c)
	}
}
```

## 5、timerCtx

### 5.1、基础类型

```go
type timerCtx struct {
	cancelCtx
	timer *time.Timer 

	deadline time.Time
}

func (c *timerCtx) Deadline() (deadline time.Time, ok bool) {
	return c.deadline, true
}
```

`timer`声明了一个定时器，用于发送截止时间

### 5.2、实现方法

```go
func WithDeadline(parent Context, d time.Time) (Context, CancelFunc) {
	if cur, ok := parent.Deadline(); ok && cur.Before(d) {
		return WithCancel(parent)
	}
	c := &timerCtx{
		cancelCtx: newCancelCtx(parent),
		deadline:  d,
	}
	propagateCancel(parent, c)
	dur := time.Until(d)
	if dur <= 0 {
		c.cancel(true, DeadlineExceeded) 
		return c, func() { c.cancel(false, Canceled) }
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err == nil {
		c.timer = time.AfterFunc(dur, func() {
			c.cancel(true, DeadlineExceeded)
		})
	}
	return c, func() { c.cancel(true, Canceled) }
}
```

大致和`cancelCtx`差不多，多了声明的定时器，用于发送截止时间。

而`timerCtx.cancel`有些不一样，是关闭定时器的。

```go
func (c *timerCtx) cancel(removeFromParent bool, err error) {
	c.cancelCtx.cancel(false, err)
	if removeFromParent {
		removeChild(c.cancelCtx.Context, c)
	}
	c.mu.Lock()
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	c.mu.Unlock()
}
```

关于`timerCtx`还有一个方法

```go
func WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc) {
	return WithDeadline(parent, time.Now().Add(timeout))
}
```

与`WithDeadline`类似，只不过是创建了一个过期时间的context

## 6、总结

- context主要用于父子之间同步信号，本质上是一种协程调度方式
- context是线程安全的，因为context本身不变
- 父context通知子context取消，但是不会干涉子任务的执行，也就是说context的取消机制是无侵入的
- 子context的取消是不会影响父context的

