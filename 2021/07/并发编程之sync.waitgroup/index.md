# 并发编程之WaitGroup


`waitgroup`的使用场景：

一个`waitgroup`对象可以等到一组协程结束，也就是等待一组`goroutine`返回。

首先我们来看看`sync.WaitGroup`的结构：

```go
// A WaitGroup must not be copied after first use.
type WaitGroup struct {
	noCopy noCopy

	// 64-bit value: high 32 bits are counter, low 32 bits are waiter count.
	// 64-bit atomic operations require 64-bit alignment, but 32-bit
	// compilers do not ensure it. So we allocate 12 bytes and then use
	// the aligned 8 bytes in them as state, and the other 4 as storage
	// for the sema.
	// 64bit(8bytes)的值分成两段，高32位是计数值，低32位是waiter的计数
	// 64位值的原子操作需要在64位编译器上，但32位不支持，所以使用12bytes，8bytes表示状态，4bytes表示信号量
	state1 [3]uint32
}
```

这里总共就2个字段，一个是`nocopy`是为了保证该结构不会被拷贝，是一种保护机制。一个是`state1`主要是存储状态和信号量，这里使用的8字节对齐。

这里的`state1`一共被分配了12个字节，被设定成3种状态：

- 其中对齐的8个字节作为状态，高32位为计数的数量，低32位为等待的`goroutine`数量
- 其中的4个字节作为信号量存储

```go
// state returns pointers to the state and sema fields stored within wg.state1.
func (wg *WaitGroup) state() (statep *uint64, semap *uint32) {
	if uintptr(unsafe.Pointer(&wg.state1))%8 == 0 {
		// 如果是64位，数组前两个元素做state，后一个元素做信号量
		return (*uint64)(unsafe.Pointer(&wg.state1)), &wg.state1[2]
	} else {
		// 如果是32位，数组后两个元素做state，第一个元素做信号量
		return (*uint64)(unsafe.Pointer(&wg.state1[1])), &wg.state1[0]
	}
}
```

为了保证`waitgroup`在32位平台上使用，就不能分成2个字段来写，考虑到字段的顺序平台的不同，内存对齐的方式不同，因此这里判断数组的首地址是否处于8字节对齐的位置上。

当数组的首地址是处于一个`8`字节对齐的位置上时，那么就将这个数组的前`8`个字节作为`64`位值使用表示状态，后`4`个字节作为`32`位值表示信号量(`semaphore`)。同理如果首地址没有处于`8`字节对齐的位置上时，那么就将前`4`个字节作为`semaphore`，后`8`个字节作为`64`位数值。画个图表示一下：

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/16/1085709093.png)

`waitgroup`提供了`Add`方法增加一个计数器，`Done`方法减掉一个计数器，而`Done`方法实际上就是`Add(-1)`。

所以我们来看看`Add()`方法：

```go
// Add主要操作state的计数值部分（高32位）
func (wg *WaitGroup) Add(delta int) {
	statep, semap := wg.state()
	// 将delta添加到计数值上
	state := atomic.AddUint64(statep, uint64(delta)<<32)
	// 当前的计数值
	v := int32(state >> 32)
	// 当前的waiter
	w := uint32(state)
	if v < 0 {
		panic("sync: negative WaitGroup counter")
	}
	// Add(1)必须在Wait之前
	if w != 0 && delta > 0 && v == int32(delta) {
		panic("sync: WaitGroup misuse: Add called concurrently with Wait")
	}
	if v > 0 || w == 0 {
		return
	}
	// This goroutine has set counter to 0 when waiters > 0.
	// Now there can't be concurrent mutations of state:
	// - Adds must not happen concurrently with Wait,
	// - Wait does not increment waiters if it sees counter == 0.
	// Still do a cheap sanity check to detect WaitGroup misuse.
	// 如果计数值v=0且waiter>0，那么state的值就是waiter的数量
	// 将waiter设置为0，唤醒所有的waiter
	if *statep != state {
		panic("sync: WaitGroup misuse: Add called concurrently with Wait")
	}
	// Reset waiters count to 0.
	*statep = 0
	for ; w != 0; w-- {
		runtime_Semrelease(semap, false, 0)
	}
}
```

而`Wait`方法会阻塞`goroutine`知道`waitgroup`的计数器变为0。

```go
// 不断检查state的值，如果其中计数值为0，说明所有的子goroutine已全部执行完毕，调用者不必等待，全部返回。
// 如果计数值>0,说明此时还有任务没有完成，那么调用者变成等待者，需要加入wait队列，并且阻塞自己
func (wg *WaitGroup) Wait() {
	statep, semap := wg.state()
	for {
		state := atomic.LoadUint64(statep)
		v := int32(state >> 32) // 计数值（Add）
		w := uint32(state)      // waiter
		if v == 0 {
			// Counter is 0, no need to wait.
			return
		}
		// Increment waiters count.
		if atomic.CompareAndSwapUint64(statep, state, state+1) {
			runtime_Semacquire(semap)
			// 阻塞完成，所有的Add已经完成
			if *statep != 0 {
				panic("sync: WaitGroup is reused before previous Wait has returned")
			}
			return
		}
	}
}
```

**小结**

- `Add`方法与`Wait`方法不可以并发同时调用，`Add`方法必须在`Wait`方法之前调用
- `Add`方法必须与实际等待的`goroutine`数量一致，否则会panic
- 调用`Wait`方法后，必须等待`Wait`方法返回后才能重新使用`waitgroup`，也就是不能再`wait`没有返回前调用`Add`
-  `waitgroup`对象只能有一份，不可以拷贝给其他变量。
