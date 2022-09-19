---
title: "sync之Pool"
date: 2021-07-16T10:53:02+08:00
draft: false

tags: ['analysis','sync']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

之前的文章[httprouter路由框架为什么高性能](https://www.toutiao.com/i7039232655602532897/)提到过一点高性能的原因就是它减少了内存分配。因为分配内存是在堆上分配的，调用`mallocgc`函数，是有性能消耗的。

而`httprouter`中使用`sync.pool`来减少内存分配，减少`GC`消耗。

那么`sync.Pool`为什么能做到这一点？做出来哪些减少性能消耗的工作？

## 一、初识`sync.Pool`

`sync.Pool`是一组可以单独保存和检索的临时对象。存储在`Pool`中的任意对象可能会自动删除，这个删除过程是不会通知到用户的。

`Pool`的目的是缓存已分配但没有使用的对象以供之后复用，减轻垃圾回收的压力。而`Pool`是并发安全的，也就是说，它可以轻松构建高效、线程安全的存储池。

一个例子就是在`fmt`包中，`Pool`维护了一个动态大小的临时输出缓冲区存储，存储在负载的时候扩展（多goroutine打印），在静止时缩小。

## 二、使用方法

```go
bufferpool := &sync.Pool{
	New: func() interface{} {
		println("Create new instance")
		return struct{}{}
	},
}
buffer := bufferpool.Get()
bufferpool.Put(buffer)
```

首先初始化`Pool`，声明一个创建`Pool`元素的方法。

然后当使用时申请对象，`Get`方法会返回`Pool`已经存在的对象，如果没有，就走`New`方法来初始化一个对象。

当使用完成后，调用`Put`方法把对象放回`Pool`中。

`Pool`就3个接口，针对所有的对象类型都可以使用。

---

那么我们来思考一个问题，使用`sync.Pool`有什么好处？

下面我们来看一个例子

```go
var count int32

func newBuffer() interface{} {
	atomic.AddInt32(&count, 1)
	buffer := make([]byte, 1024)
	return &buffer
}

func main() {
	bufferPool := &sync.Pool{
		New: newBuffer,
	}

	workers := 1024 * 1024
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buffer := bufferPool.Get()
			_ = buffer.(*[]byte)
			defer bufferPool.Put(buffer)
		}()
	}
	wg.Wait()
	fmt.Printf("%d buffer created", count)
}
```

最终打印结果

```text
11 buffer created
10 buffer created
```

多次运行可能会出现不同的结果，但是次数`count`都不大。如果不是使用`Pool`来申请，而是直接使用`buffer := make([]byte, 1024)`来申请内存，那么就会申请 1024 * 1024 个对象，造成极大的浪费。而`Pool`就是对这类对象的复用。

## 三、原理

既然已经知道了复用对象的好处，那么`sync.Pool`到底是如何实现这一功能的呢？

首先我们来看看`Pool`的结构

```go
type Pool struct {
	noCopy noCopy

	local     unsafe.Pointer 
	localSize uintptr       

	victim     unsafe.Pointer 
	victimSize uintptr        

	New func() interface{}
}
```

- `nocopy`就是标识不能拷贝，具体原理在[读写锁](https://www.toutiao.com/i7041552636310602273/)时提到
- `localSize`就是cpu处理器的个数，`local`指向了 `[localSize]poolLocal`
- `victim`和`victimSize`就是在GC后接管`local`和`localSize`
- `New`函数就是初始化对象的方法

`poolLocal`管理`Pool`池里的cache元素的关键结构

```go
type poolLocalInternal struct {
	private interface{} 
	shared poolChain 
}
type poolLocal struct {
	poolLocalInternal
	pad [128 - unsafe.Sizeof(poolLocalInternal{})%128]byte
}
```

- `private`就是声明的对象
- `shared`是**双链表结构**，用于挂载cache元素
- `pad`就是用来填充字符到128字节，用于内存对齐

### 1、获取对象

#### 1.1、获取本地pool

```go
l, pid = p.pin()
```

这个`pin`函数`hold`住了当前goroutine在`P`上，不允许调度，并且返回`P`的本地`pool`和`P`的id。

```go
func (p *Pool) pin() (*poolLocal, int) {
	pid := runtime_procPin()
	s := atomic.LoadUintptr(&p.localSize) 
	l := p.local                          
	if uintptr(pid) < s {
		return indexLocal(l, pid), pid
	}
	return p.pinSlow()
}
```

这个`indexLocal`其实就是个索引到本地`pool`的指针

```go
func indexLocal(l unsafe.Pointer, i int) *poolLocal {
	lp := unsafe.Pointer(uintptr(l) + uintptr(i)*unsafe.Sizeof(poolLocal{}))
	return (*poolLocal)(lp)
}
```

通常只有第一次执行的时候，`p.localSize`为0，才会执行`p.pinSlow`，其他都直接走`if`返回本地`pool`了。

`pinSlow`就是把`Pool`注册进`allPools`数组中

```go
func (p *Pool) pinSlow() (*poolLocal, int) {
	runtime_procUnpin()

	allPoolsMu.Lock()
	defer allPoolsMu.Unlock()
	pid := runtime_procPin()
	s := p.localSize
	l := p.local
	if uintptr(pid) < s {
		return indexLocal(l, pid), pid
	}
	if p.local == nil {
		allPools = append(allPools, p)
	}
	size := runtime.GOMAXPROCS(0)
	local := make([]poolLocal, size)
	atomic.StorePointer(&p.local, unsafe.Pointer(&local[0])) 
	atomic.StoreUintptr(&p.localSize, uintptr(size))        
	return &local[pid], pid
}
```

首先先解锁，然后加全局互斥锁

```go
var (
	allPoolsMu Mutex
	allPools []*Pool
	oldPools []*Pool
)
```

`allPools`就是全局的`pool`，`oldPool`就是`victim`使用的`pool`。

然后再重新`hold`住`goroutine`在`P`上，二次判断是否直接返回本地`pool`。

而使用`runtime.GOMAXPROCS(0)`来获取cpu的数量，也就是`P`的数量。

---

这里深入扩展一下，`runtime_procPin`其实是`runtime`包下的`procPin`的一层封装。

```go
func procPin() int {
	_g_ := getg()
	mp := _g_.m

	mp.locks++
	return int(mp.p.ptr().id)
}
```

`procPin`的目的就是为了当前`G`被抢占了执行权限，也就是说`G`在`M`上不走了，而实际核心是`mp.locks++`，在`newstack`函数里，有这么段代码

```go
if preempt {
	if !canPreemptM(thisg.m) {
		gp.stackguard0 = gp.stack.lo + _StackGuard
		gogo(&gp.sched) 
	}
}

func canPreemptM(mp *m) bool {
	return mp.locks == 0 && mp.mallocing == 0 && mp.preemptoff == "" && mp.p.ptr().status == _Prunning
}
```

这里`mp.locks>0`，所以就只能让`G`一直执行

而`runtime_procUnpin`函数可以猜想的到，就是让`mp.lock--`。

---

#### 1.2、取出对象

```go
x := l.private
l.private = nil
if x == nil {
	x, _ = l.shared.popHead()
	if x == nil {
		x = p.getSlow(pid)
	}
}
```

从`private`中取出对象，如果取出的对象为`nil`，那么就尝试从`share`队列中获取，如果还是`nil`，就从其他`P`的队列中取，或者从`victim`中取。

```go
func (p *Pool) getSlow(pid int) interface{} {
	size := atomic.LoadUintptr(&p.localSize) 
	locals := p.local            
    // 从其他P中取
	for i := 0; i < int(size); i++ {
		l := indexLocal(locals, (pid+i+1)%int(size))
		if x, _ := l.shared.popTail(); x != nil {
			return x
		}
	}

    // 从victim中取
	size = atomic.LoadUintptr(&p.victimSize)
	if uintptr(pid) >= size {
		return nil
	}
	locals = p.victim
	l := indexLocal(locals, pid)
	if x := l.private; x != nil {
		l.private = nil
		return x
	}
	for i := 0; i < int(size); i++ {
		l := indexLocal(locals, (pid+i)%int(size))
		if x, _ := l.shared.popTail(); x != nil {
			return x
		}
	}

	atomic.StoreUintptr(&p.victimSize, 0)

	return nil
}
```

#### 1.3、初始化对象

如果上面几个地方都不存在该对象，那么就调用`New`函数初始化一个对象返回

```go
if x == nil && p.New != nil {
	x = p.New()
}
return x
```

### 2、放回对象

#### 2.1、空值判断

```go
if x == nil {
	return
}
```

#### 2.2、获取本地pool

```go
l, _ := p.pin()
```

#### 2.3、尝试存放数据

```go
if l.private == nil {
	l.private = x
	x = nil
}
if x != nil {
	// 放到双向链表
	l.shared.pushHead(x)
}
```

### 3、victim

看到这里，可能就有点疑惑了，`Pool`就这两个方法，也没有用到`victim`。

这个奥秘就在于它注册了`init`函数，在每次GC的时候调用`poolCleanup`函数，也就是说每一轮GC都会对所有的`Pool`做清理工作。

```go
func init() {
	runtime_registerPoolCleanup(poolCleanup)
}
```

而`poolCleanup`函数就是做`pool`的迁移

```go
func poolCleanup() {
	for _, p := range oldPools {
		p.victim = nil
		p.victimSize = 0
	}

	for _, p := range allPools {
		p.victim = p.local
		p.victimSize = p.localSize
		p.local = nil
		p.localSize = 0
	}

	oldPools, allPools = allPools, nil
}
```

## 四、总结

1、`sync.Pool`是并发安全的，读取数据时会`hold`住当前的goroutine不被打断

2、`sync.Pool`不允许复制后使用，因为nocopy

3、`sync.Pool`不适用于`socket`长连接或连接池等，因为无法知道连接池的个数，连接池的元素随时可能会被释放。

4、从`sync.Pool`取出的对象使用完需要放回池中。