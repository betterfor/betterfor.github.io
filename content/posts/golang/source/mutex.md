---
title: "Mutex的源码解析"
date: 2021-02-26T14:46:05+08:00
draft: false

tags: ['golang',"源码分析"]
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: false
---

我们来看一下`sync`包下有哪些常见的使用：`cond.go` `map.go` `mutex.go` `once.go` `pool.go` `rwmutex.go` `waitgroup.go`

## 什么是sync？

> Package sync provides basic synchronization primitives such as mutual exclusion locks. Other than the Once and WaitGroup types, most are intended for use by low-level library routines. Higher-level synchronization is better done via channels and communication.
>
> Values containing the types defined in this package should not be copied.

这句话的大意是：

> 包同步提供基本的同步原语，例如互斥锁。 除一次和等待组类型外，大多数都供低级库例程使用。 较高级别的同步最好通过渠道和通信来完成。
>
> 包含此包中定义的类型的值不应复制。

## 互斥锁(一代锁)

> 先介绍一下 a &^ b是怎么一回事？
>
> > a &^ b = (a&b)^a, 作用是以a为基础，与b相异的部分保留，相同位清0。换言之，清除a中ab都为1的位。

```go
func (m *Mutex) Lock() {
    // 快速加锁，将state状态更新为locked
	if atomic.CompareAndSwapInt32(&m.state, 0, mutexLocked) {
		return
	}

	awoke := false // 当前goroutine是否被唤醒
	for {
		old := m.state	// 保存state状态
		new := old | mutexLocked // 新值设为locked
		if old&mutexLocked != 0 { // 如果处于加锁状态，新的goroutine加入队列
			new = old + 1<<mutexWaiterShift
		}
		if awoke {
			// 如果被唤醒，新值需要重置为0
			new &^= mutexWoken
		}
         // 两种情况会走到这里：1、休眠中被唤醒；2、加锁失败重新进入循环
         // cas更新，如果更新失败，说明有其他goroutine抢先，重新循环
		if atomic.CompareAndSwapInt32(&m.state, old, new) {
             // 如果state更新成功
             // 1、old为0，抢锁成功，break
             // 2、old为1，cas只是为了更新waiter计数
			if old&mutexLocked == 0 {
				break
			}
             // 阻塞等待唤醒
			runtime_Semacquire(&m.sema)
             // 有goroutine释放了锁，当前goroutine被唤醒
			awoke = true
		}
	}
}

func (m *Mutex) Unlock() {
    // 更新state为unlocked
	new := atomic.AddInt32(&m.state, -mutexLocked)
	if (new+mutexLocked)&mutexLocked == 0 { // 0&1=0，说明state是0，也就是说没有加锁的锁解锁会panic
		panic("sync: unlock of unlocked mutex")
	}

	old := new
	for {
		// 不需要唤醒的情况
         // 1、等待队列为0
         // 2、goroutine已经抢到锁了
         // 3、已经有goroutine被唤醒了
		if old>>mutexWaiterShift == 0 || old&(mutexLocked|mutexWoken) != 0 {
			return
		}
		// waiter计数位减1，设置state为woken，可能会有多个goroutine被唤醒
		new = (old - 1<<mutexWaiterShift) | mutexWoken
		if atomic.CompareAndSwapInt32(&m.state, old, new) {
			runtime_Semrelease(&m.sema) // 唤醒睡眠的goroutine
			return
		}
		old = m.state
	}
}
```

