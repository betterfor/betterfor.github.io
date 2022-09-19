---
title: "并发编程之互斥锁"
date: 2021-07-16T10:52:20+08:00
draft: false

tags: ['analysis','sync']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

并发必然会带来对于资源的竞争，这时需要使用go提供的`sync.Mutex`这把互斥锁来保证临界资源的访问互斥了。

## 锁的性质

在代码注释开篇就有一大段注释，里面讲了锁的设计理念。大致意思如下：

> 锁有两种模式：正常模式和饥饿模式。
> 在正常模式下，所有的等待锁的goroutine都会存在一个先进先出的队列中（轮流被唤醒）
> 但是一个被唤醒的goroutine并不是直接获得锁，而是仍然需要和那些新请求锁的（new arrivial）的goroutine竞争，而这其实是不公平的，因为新请求锁的goroutine有一个优势——它们正在CPU上
> 运行，并且数量可能会很多。所以一个被唤醒的goroutine拿到锁的概率是很小的。在这种情况下，
> 这个被唤醒的goroutine会加入到队列的头部。如果一个等待的goroutine有超过1ms（写死在代码中）
> 都没获取到锁，那么就会把锁转变为饥饿模式。
>
> 在饥饿模式中，锁的所有权会直接从释放锁(unlock)的goroutine转交给队列头的goroutine，
>  新请求锁的goroutine就算锁是空闲状态也不会去获取锁，并且也不会尝试自旋。它们只是排到队列的尾部。
>
>  如果一个goroutine获取到了锁之后，它会判断以下两种情况：
>  1. 它是队列中最后一个goroutine；
>  2. 它拿到锁所花的时间小于1ms；
>  以上只要有一个成立，它就会把锁转变回正常模式。
>
>  正常模式会有比较好的性能，因为即使有很多阻塞的等待锁的goroutine，
>  一个goroutine也可以尝试请求多次锁。
>  饥饿模式对于防止尾部延迟来说非常的重要。

## 字段定义

```go
// A Mutex must not be copied after first use.
type Mutex struct {
	state int32  // 锁的当前状态
	sema  uint32 // 信号量，用户唤醒goroutine
}

const (
	// 是否加锁的标识
	mutexLocked = 1 << iota // mutex is locked
	mutexWoken
	mutexStarving
	mutexWaiterShift = iota

	// Mutex fairness.
	starvationThresholdNs = 1e6
)
```

state的状态：
- mutexLocked：对应低1位bit代表锁被占用，0标识锁空闲
- mutexWoken：对应低2位bit代表已唤醒，0标识未唤醒
- mutexStarving：对应低3位bit代表处于饥饿模式，0标识正常模式
- mutexWaiterShift：3(011)，`m.state>>mutexWaiterShift`得到当前阻塞的goroutine数目，最多可以阻塞`2^29^`个goroutine。

![mutex state](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/19/mutex_state.png)

## Lock

```go
func (m *Mutex) Lock() {
	// Fast path: grab unlocked mutex.
	// 判断是否可以加锁。
	// 第一个可以直接加锁返回
	if atomic.CompareAndSwapInt32(&m.state, 0, mutexLocked) {
		return
	}
	// Slow path (outlined so that the fast path can be inlined)
	m.lockSlow()
}

func (m *Mutex) lockSlow() {
	var waitStartTime int64
	// 饥饿模式
	starving := false
	// 协程唤醒
	awoke := false
	// 循环次数
	iter := 0
	// 当前锁状态
	old := m.state
	for {
		// Don't spin in starvation mode, ownership is handed off to waiters
		// so we won't be able to acquire the mutex anyway.
		// 条件一：old被获取到锁，但不处于饥饿状态。如果处于饥饿状态，锁的所有权直接交给等待队列第一个
		// 条件二：可以自旋，多核、压力不大并且在一定次数内可以自旋。sync_runtime_canSpin的实现
		if old&(mutexLocked|mutexStarving) == mutexLocked && runtime_canSpin(iter) {
			// Active spinning makes sense.
			// Try to set mutexWoken flag to inform Unlock
			// to not wake other blocked goroutines.
			// 自旋过程中如果发现state没有设置唤醒标识，添加awoke标识，并标记自己已唤醒
			if !awoke && old&mutexWoken == 0 && old>>mutexWaiterShift != 0 &&
				atomic.CompareAndSwapInt32(&m.state, old, old|mutexWoken) {
				awoke = true
			}
			// 主动自旋
			runtime_doSpin()
			iter++
			old = m.state
			continue
		}
		// 到了这一步：state的状态可能是
		// 1、锁没有释放，锁处于正常状态（011）
		// 2、锁没有释放，锁处于饥饿状态（111）
		// 3、锁已经释放，锁处于正常状态（010）
		// 4、锁已经释放，锁处于饥饿状态（110）

		// 复制一个新的状态
		new := old
		// Don't try to acquire starving mutex, new arriving goroutines must queue.
		// 如果不是饥饿状态，new设置锁，尝试获取锁
		// 如果处于饥饿状态，不设置状态
		if old&mutexStarving == 0 {
			new |= mutexLocked // 标记为获取锁（实际上还没有获取到）
		}
		// 如果old锁处于被获取或饥饿状态，就把期望状态的等待队列的等待者数量+1
		if old&(mutexLocked|mutexStarving) != 0 {
			new += 1 << mutexWaiterShift
		}
		// The current goroutine switches mutex to starvation mode.
		// But if the mutex is currently unlocked, don't do the switch.
		// Unlock expects that starving mutex has waiters, which will not
		// be true in this case.
		// 如果处于饥饿状态，并且state已经被加锁，将new state标记为饥饿状态
		if starving && old&mutexLocked != 0 {
			new |= mutexStarving
		}
		if awoke {
			// The goroutine has been woken from sleep,
			// so we need to reset the flag in either case.
			// goroutine已经被唤醒，因此需要reset
			if new&mutexWoken == 0 {
				throw("sync: inconsistent mutex state")
			}
			// 设为未唤醒状态
			new &^= mutexWoken
		}
		// 原子更新state
		if atomic.CompareAndSwapInt32(&m.state, old, new) {
			// 如果old状态不是饥饿状态也不是被获取状态，代表当前goroutine已经获取了锁
			if old&(mutexLocked|mutexStarving) == 0 {
				break // locked the mutex with CAS
			}
			// If we were already waiting before, queue at the front of the queue.
			// 如果之前在等待了，就排在队列前面
			queueLifo := waitStartTime != 0
			// 如果没有等待过，初始化等待时间
			if waitStartTime == 0 {
				waitStartTime = runtime_nanotime()
			}
			// 如果queueLifo为true，将等待服务方针等待队列队头，被阻塞
			runtime_SemacquireMutex(&m.sema, queueLifo, 1)
			// 阻塞被唤醒

			// 如果是饥饿状态或等待超过1ms，将当前goroutine状态设置为饥饿
			starving = starving || runtime_nanotime()-waitStartTime > starvationThresholdNs
			old = m.state
			// 如果是饥饿状态
			if old&mutexStarving != 0 {
				// If this goroutine was woken and mutex is in starvation mode,
				// ownership was handed off to us but mutex is in somewhat
				// inconsistent state: mutexLocked is not set and we are still
				// accounted as waiter. Fix that.
				if old&(mutexLocked|mutexWoken) != 0 || old>>mutexWaiterShift == 0 {
					throw("sync: inconsistent mutex state")
				}
				// 当前的goroutine获取锁，waiter-1
				delta := int32(mutexLocked - 1<<mutexWaiterShift)
				// 如果当前goroutine不是饥饿状态或当前goroutine是队列中最后一个，退出饥饿模式，状态设为正常
				if !starving || old>>mutexWaiterShift == 1 {
					// Exit starvation mode.
					// Critical to do it here and consider wait time.
					// Starvation mode is so inefficient, that two goroutines
					// can go lock-step infinitely once they switch mutex
					// to starvation mode.
					delta -= mutexStarving
				}
				atomic.AddInt32(&m.state, delta)
				break
			}
			awoke = true
			iter = 0
		} else {
			// cas不成功，说明没有成功获取到锁，更新old
			old = m.state
		}
	}
}
```

**加锁流程**

1、原子判断是否可以加锁，如果当前锁没有被使用，当前goroutine获取锁，结束本次Lock操作

2、如果已经被别的goroutine持有了，启动一个for循环去抢占锁：

会存在两种状态的切换：饥饿状态和正常状态

如果一个等待的goroutine有超过1ms没有获取到锁，那么把锁转换为饥饿模式；

如果一个goroutine获取到锁后
- 1、它是队列中最后一个goroutine
- 2、它拿到锁花费的时间小于1ms

上面的两个只要有一个条件成立，就会把锁转为正常状态。

3、如果锁已经被其他goroutine持有了，但不是饥饿状态，并且满足自旋状态，当前goroutine会不断自旋，等待锁被释放

4、不满足自旋条件的goroutine，结束自旋状态

5、如果`old.state`不是饥饿状态，新的goroutine会去尝试获取锁，如果是饥饿状态，就直接把锁交给等待队列的第一个

6、如果锁时被获取或饥饿状态，等待者数量+1

7、当本goroutine被唤醒了，要么持有锁，要么重新进入休眠状态

8、如果`old.state`的状态是未锁状态，并且锁不处于饥饿状态，那么当前goroutine已经获取了锁的拥有权，结束Lock

9、判断当前的goroutine是新来的还是刚被唤醒的，新来的加入到等待队列的尾部，刚被唤醒的加入等待队列的头部，然后通过信号量阻塞，直到当前goroutine被唤醒

10、判断如果当前state是否是饥饿状态，不是的唤醒本次goroutine，继续循环

11、是饥饿状态，当前goroutine设置锁，等待者-1，如果当前goroutine是队列中的最后一个，将锁设为正常状态，拿到锁结束Lock

![lock](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/19/mutex_lock.png)

## UnLock

```go
func (m *Mutex) Unlock() {
	if race.Enabled {
		_ = m.state
		race.Release(unsafe.Pointer(m))
	}

	// Fast path: drop lock bit.
	// 修改锁的状态
	new := atomic.AddInt32(&m.state, -mutexLocked)
	if new != 0 {
		// 如果new=0，说明只有一个Lock并且被解开了
		// Outlined slow path to allow inlining the fast path.
		// To hide unlockSlow during tracing we skip one extra frame when tracing GoUnblock.
		m.unlockSlow(new)
	}
}

func (m *Mutex) unlockSlow(new int32) {
	// （new+1）&1==0，new=-1，也就是上面已经Unlock后又调用一次Unlock会出现这种情况
	if (new+mutexLocked)&mutexLocked == 0 {
		throw("sync: unlock of unlocked mutex")
	}
	if new&mutexStarving == 0 {
		// 不是饥饿状态
		old := new
		for {
			// 如果锁没有等待拿锁的goroutine
			// 或锁被获取了（在循环过程中被其他goroutine获取了）
			// 或锁是被唤醒状态（表示有goroutine被唤醒，不需要再去尝试唤醒其他goroutine）
			// 或者锁是饥饿状态（会直接交给队列头的goroutine）
			// 那么直接返回
			if old>>mutexWaiterShift == 0 || old&(mutexLocked|mutexWoken|mutexStarving) != 0 {
				return
			}
			// Grab the right to wake someone.
			// 将等待队列-1，设置woken标识
			new = (old - 1<<mutexWaiterShift) | mutexWoken
			// 设置新的state，通过信号量会唤醒一个阻塞的goroutine去获取锁
			if atomic.CompareAndSwapInt32(&m.state, old, new) {
				runtime_Semrelease(&m.sema, false, 1)
				return
			}
			old = m.state
		}
	} else {
		// 饥饿模式下，直接将锁的所有权转给等待队列中的第一个。
		// 注意此时state的mutexLocked还没有设置，唤醒的goroutine会设置它。
		// 在此期间，如果有新的goroutine来请求锁，因为mutex处于饥饿状态，mutex还会被认为处于锁的状态，新来的goroutine不会抢占锁
		runtime_Semrelease(&m.sema, true, 1)
	}
}
```

**解锁流程**

1、判断锁的状态，不能重复解锁

2、如果锁是正常模式，会不断尝试解锁

3、如果锁时饥饿模式，通过信号量，唤醒饥饿模式下Lock操作队列中第一个goroutine

![unlock](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/19/mutex_unlock.png)

## 总结

- 加锁过程会存在正常模式和饥饿模式的转换
- 饥饿模式是保证锁的公平性，正常模式下的互斥锁能提供更好的性能，饥饿模式能避免goroutine由于陷入等待无法获取锁造成的高尾延迟
- 锁的状态切换，用的是位运算
- 一个已经锁定的互斥锁，只能被解锁一次

### 如果atomic可以保证原子性，那么和mutex有什么区别呢？

> Mutexes are slow, due to the setup and teardown, and due to the fact that they block other goroutines for the duration of the lock.
> Atomic operations are fast because they use an atomic CPU instruction, rather than relying on external locks to.

互斥锁其实是通过阻塞其他协程起到了原子操作的功能，而atomic是通过控制更底层的CPU指令，来达到值操作的原子性。

mutex类似于悲观锁，总是假设会有并发的操作要修改被操作的值，所以使用锁将相关操作放入临界区加以保护

而原子锁CAS趋向于乐观锁，总是假设被操作值未曾修改（与旧值相等），一旦确认就立即进行值替换。在值被频繁变更的情况下，CAS操作并不是容易成功需要不断尝试。