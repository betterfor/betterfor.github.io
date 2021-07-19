# 并发编程之sync.Pool


我们通常用golang来构建高并发场景下的应用，但是由于golang内建的GC机制会影响应用的性能，为了减少GC，golang提供了对象重用的机制，也就是`sync.Pool`对象池。`sync.Pool`是可伸缩的，并发安全的。其大小仅受限于内存的大小，可以被看作是一个存放可重用对象的值的容器。 设计的目的是存放已经分配的但是暂时不用的对象，在需要用到的时候直接从pool中取。

任何存放区其中的值可以在任何时候被删除而不通知，在高负载下可以动态的扩容，在不活跃时对象池会收缩。

## 使用方法

```go
func main() {
	// 初始化Pool实例New
	// New方法声明Pool元素创建的方法
	bufferpool := &sync.Pool{
		New: func() interface{} {
			println("Create new instance")
			return struct{}{}
		},
	}
	// 申请对象
	// Get方法会返回Pool已经存在的对象，如果没有，就走慢路径，也就是调用初始化的时候定义的New方法来初始化一个对象
	buffer := bufferpool.Get()
	// 释放对象
	// 使用对象后，调用Put方法声明把对象放回池子。
	// 这个调用之后仅仅是把这个对象放回池子，池子里的对象什么时候真正释放外界不清楚，不受外界控制。
	bufferpool.Put(buffer)
}
```

## Pool结构体

```go
// A Pool must not be copied after first use.
type Pool struct {
	noCopy noCopy

	// 数组，对应每个P，数量和P的数量保持一致
	local     unsafe.Pointer // local fixed-size per-P pool, actual type is [P]poolLocal
	localSize uintptr        // size of the local array

	// GC到时，victim和victimSize分别接管local和localSize
	// victim 的目的是为了减少GC后冷启动导致的性能抖动，让分配对象更加平滑
	victim     unsafe.Pointer // local from previous cycle
	victimSize uintptr        // size of victims array

	// New optionally specifies a function to generate
	// a value when Get would otherwise return nil.
	// It may not be changed concurrently with calls to Get.
	New func() interface{}
}

// poolLocal管理Pool池里cache元素的关键结构，Pool.local指向这个类型的数组，
type poolLocal struct {
	poolLocalInternal

	// Prevents false sharing on widespread platforms with
	// 128 mod (cache line size) = 0 .
	// 把poolLocal填充至128字节对齐，避免false sharing引起的性能问题
	pad [128 - unsafe.Sizeof(poolLocalInternal{})%128]byte
}

// 管理cache的内部结构，跟每个P对应，操作无须加锁
type poolLocalInternal struct {
	// 每个P的私有，使用时无需加锁
	private interface{} // Can be used only by the respective P.
	// 双链表结构，用于挂接cache元素
	shared poolChain // Local P can pushHead/popHead; any P can popTail.
}
```

这里的`poolChain`是一个双链表结构，里面包含了头插、头出、尾出的方法。

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/19/2554756621.png)

我们注意到`Pool`里是没有锁的，但是却实现了并发安全，这里我们详细看一下实现

## pin

```go
func (p *Pool) pin() (*poolLocal, int) {
	// 把G锁住在当前M（声明当前M不能被抢占），返回M绑定的P的ID
	pid := runtime_procPin()
	// In pinSlow we store to local and then to localSize, here we load in opposite order.
	// Since we've disabled preemption, GC cannot happen in between.
	// Thus here we must observe local at least as large localSize.
	// We can observe a newer/larger local, it is fine (we must observe its zero-initialized-ness).
	s := atomic.LoadUintptr(&p.localSize) // load-acquire
	l := p.local                          // load-consume
	if uintptr(pid) < s {
		return indexLocal(l, pid), pid
	}
	return p.pinSlow()
}

// 一般是Pool第一次调用Get的时候才会走进来（每个 P 的第一次调用）
// 把Pool注册进allPools数组；
// Pool.local 数组按照P的个数(cpu的个数)进行分配
func (p *Pool) pinSlow() (*poolLocal, int) {
	// Retry under the mutex.
	// Can not lock the mutex while pinned.
	// G-M先解锁
	runtime_procUnpin()

	// 以下逻辑在全局锁allPoolsMu内
	allPoolsMu.Lock()
	defer allPoolsMu.Unlock()
	// 获取当前G-M-P，P的id
	pid := runtime_procPin()
	// poolCleanup won't be called while we are pinned.
	s := p.localSize
	l := p.local
	if uintptr(pid) < s {
		return indexLocal(l, pid), pid
	}
	if p.local == nil {
		// 把自己注册进allPools数组
		allPools = append(allPools, p)
	}
	// If GOMAXPROCS changes between GCs, we re-allocate the array and lose the old one.
	// P的个数
	size := runtime.GOMAXPROCS(0)
	// local数组的大小等于P的个数
	local := make([]poolLocal, size)
	atomic.StorePointer(&p.local, unsafe.Pointer(&local[0])) // store-release
	atomic.StoreUintptr(&p.localSize, uintptr(size))         // store-release
	return &local[pid], pid
}

func indexLocal(l unsafe.Pointer, i int) *poolLocal {
	lp := unsafe.Pointer(uintptr(l) + uintptr(i)*unsafe.Sizeof(poolLocal{}))
	return (*poolLocal)(lp)
}
```

`runtime_procPin`是`procPin`的一层封装

```go
func procPin() int {
   _g_ := getg()
   mp := _g_.m

   mp.locks++
   return int(mp.p.ptr().id)
}
```

procPin函数目的是为了当前G被抢占了执行权限（也就是说，当前G就在当前M上不走了），
这里的核心实现是`mp.locks++`操作，在`newstack`里会对此条件进行判断

```go
if preempt {
      // 已经打了抢占标识，但还需要判断条件满足才能出让执行权
      if !canPreemptM(thisg.m) {
         // Let the goroutine keep running for now.
         // gp->preempt is set, so it will be preempted next time.
         gp.stackguard0 = gp.stack.lo + _StackGuard
         gogo(&gp.sched) // never return
      }
   }
func canPreemptM(mp *m) bool {
    return mp.locks == 0 && mp.mallocing == 0 && mp.preemptoff == "" && mp.p.ptr().status == _Prunning
}  
```

这里的流程：禁止抢占GC->寻找偏移量->越界检查->返回poolLocal或加锁重建pool，并添加到allPool中。

## 放回Put

```go
// Put adds x to the pool.
func (p *Pool) Put(x interface{}) {
	if x == nil {
		return
	}
	// G-M锁定
	l, _ := p.pin()
	if l.private == nil {
		// Fast path：放回x到private
		l.private = x
		x = nil
	}
	if x != nil {
		// 放到双向链表
		l.shared.pushHead(x)
	}
	runtime_procUnpin()
}
```

**放入流程**

1、如果x为空，直接返回

2、获取`localPool`

3、如果`private`为空，把x放回`private`，并且把x置nil

4、如果x不为nil，将x放到`pool`的`shared`双向链表中

总结来说，优先放入`private`，后面再放入`shared`空间

## 取出Get

```go
func (p *Pool) Get() interface{} {
	l, pid := p.pin()
	// fast path：从private去除缓存元素
	x := l.private
	l.private = nil
	if x == nil {
		// Try to pop the head of the local shard. We prefer
		// the head over the tail for temporal locality of
		// reuse.
		// 从shared队列中获取，share的度量在Get获取，在Put投递
		x, _ = l.shared.popHead()
		if x == nil {
			// 尝试从其他P的队列中获取元素，或尝试从victim cache取元素
			x = p.getSlow(pid)
		}
	}
	// 解除锁定
	runtime_procUnpin()
	// slow path：初始化对象
	if x == nil && p.New != nil {
		x = p.New()
	}
	return x
}

func (p *Pool) getSlow(pid int) interface{} {
	// See the comment in pin regarding ordering of the loads.
	size := atomic.LoadUintptr(&p.localSize) // load-acquire
	locals := p.local                        // load-consume
	// Try to steal one element from other procs.
	// 从其他P中获取local
	for i := 0; i < int(size); i++ {
		l := indexLocal(locals, (pid+i+1)%int(size))
		if x, _ := l.shared.popTail(); x != nil {
			return x
		}
	}

	// 从victim中取出对象
	// Try the victim cache. We do this after attempting to steal
	// from all primary caches because we want objects in the
	// victim cache to age out if at all possible.
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

	// Mark the victim cache as empty for future gets don't bother
	// with it.
	atomic.StoreUintptr(&p.victimSize, 0)

	return nil
}
```

**取出流程**

1、获取`poolLocal`

2、从`private`中取出缓存元素

3、如果取出的元素为nil，则从`shared`中获取缓存元素

4、如果还为空，则从其他P的队列中取出元素

5、如果都取不到，则调用`New`方法初始化一个新的元素。

总结来说，优先从`private`空间拿，再从`shared`空间拿，还没有就从其他的`poolLocal`的`shared`空间拿，如果还没有就`New`一个返回。

## 定时清理

```go
func init() {
	// 在GC开始时，gcStart调用clearpools函数，也就是说每一轮GC都会对所有的Pool做清理工作
	runtime_registerPoolCleanup(poolCleanup)
}

func poolCleanup() {
	// 清理oldPools上的victim的元素
	for _, p := range oldPools {
		p.victim = nil
		p.victimSize = 0
	}

	// Move primary cache to victim cache.
	// 把local cache迁移到victim上
	// 这样就不至于让GC把所有的Pool都清空了，可以防止抖动
	for _, p := range allPools {
		p.victim = p.local
		p.victimSize = p.localSize
		p.local = nil
		p.localSize = 0
	}

	// The pools with non-empty primary caches now have non-empty
	// victim caches and no pools have primary caches.
	oldPools, allPools = allPools, nil
}
```

在每次GC时，把`local`移到`victim`中。

而`runtime_registerPoolCleanup`函数的具体实现在`runtime/mgc.go`中

```go
func sync_runtime_registerPoolCleanup(f func()) {
	poolcleanup = f
}

func clearpools() {
	// clear sync.Pools
	if poolcleanup != nil {
		poolcleanup()
	}
    ...
}
```

## 问题

### 1、为什么用Pool，而不是在运行时直接实例化对象？

原因：Go的内存释放是由runtime来自动处理，有GC过程

举个栗子

```go
package main

import (
   "fmt"
   "sync"
   "sync/atomic"
)

// 用来统计实例真正创建的次数
var numCalcsCreated int32

// 创建实例的函数
func createBuffer() interface{} {
   // 这里要注意下，非常重要的一点。这里必须使用原子加，不然有并发问题；
   atomic.AddInt32(&numCalcsCreated, 1)
   buffer := make([]byte, 1024)
   return &buffer
}

func main() {
   // 创建实例
   bufferPool := &sync.Pool{
      New: createBuffer,
   }

   // 多 goroutine 并发测试
   numWorkers := 1024 * 1024
   var wg sync.WaitGroup
   wg.Add(numWorkers)

   for i := 0; i < numWorkers; i++ {
      go func() {
         defer wg.Done()
         // 申请一个 buffer 实例
         buffer := bufferPool.Get()
         // buffer := createBuffer()
         _ = buffer.(*[]byte)
         // 释放一个 buffer 实例
         defer bufferPool.Put(buffer)
      }()
   }
   wg.Wait()
   fmt.Printf("%d buffer objects were created.\n", numCalcsCreated)
}
// Output:
7 buffer objects were created.
8 buffer objects were created.
```
多次运行会出现不同的结果。

创建Pool实例的时候，只要求填充了`New`函数，而没有声明或限制Pool的大小。

如果不用pool来申请，而是直接变量声明的方式,会有1024*1024个对象生成。

这就是复用对象。

### 2、sync.Pool是并发安全吗？

> A Pool is safe for use by multiple goroutines simultaneously.

当然并发安全。

因为`sync.Pool`只是本身的`Pool`数据结构并发安全，并不是说`Pool.New`函数一定线程安全。
`Pool.New`函数可能会被并发调用。

如果把`atomic.AddInt32(&numCalcsCreated, 1)`改成`numCalcsCreated++`，然后用`go run -race main.go`命令检查一下，会报出告警。

### 3、为什么sync.Pool不适合用于像socket长连接或数据库连接池？

- Pool池里的元素随时可能释放掉，释放策略完全由runtime内部管理
- Get获取到的对象元素可能是刚创建的，也可能是之前创建好cache住的，使用者无法区分
- Pool池里面的元素个数无法知道

## 总结

`sync.Pool`本质用途是增加临时对象的重用率，减少GC负担。

1、如果不是Pool.Get申请的对象，调用了Put，会如何？

Pool池中里的就不是单一的对象元素，取出的对象类型需要业务自己判断

2、为什么Get出的对象还要Put放回去？

通常是`defer Put`这种形式保证释放元素放回池子。

Get出的对象如果不Put放回去，会被GC释放，就不能复用临时对象了

3、Pool本身允许复制后使用吗？

不允许，因为有noCopy，但是可以编译通过。

因为copy之后，对于同一个Pool里面的cache对象，就有了2个对象来源。

Pool里面的无锁设计的基础是多个goroutine不会操作到同一个数据结构，Pool拷贝后就不能保证这一点了。
