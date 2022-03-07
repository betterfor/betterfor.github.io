---
title: "sync之ONCE"
date: 2021-07-16T10:53:02+08:00
draft: false

tags: ['源码解析','sync']
categories: ["月霜天的GO"]
comment: true
toc: true
autoCollapseToc: false
---

如何在代码中执行某个函数只运行一次，特别是在go这种高并发的情况下。

go给出了一个解法，`sync.Once`就是用来解决这种问题的，我们常用来初始化配置等。

---

把源码整理一下，发现源码极其简单。

```go
type Once struct {
	done uint32
	m    Mutex
}

func (o *Once) Do(f func()) {
	// todo：为什么不用cas？
	if atomic.LoadUint32(&o.done) == 0 {
		o.doSlow(f)
	}
}

func (o *Once) doSlow(f func()) {
	o.m.Lock()
	defer o.m.Unlock()
	if o.done == 0 {
		// todo：为什么用defer来计数？
		defer atomic.StoreUint32(&o.done, 1)
		f()
	}
}
```

就是使用一个标志位来标识是否调用完成，那么在此基础上，提出了两个问题：

1、为什么使用`atomic.LoadUint32`来判断，为什么不使用互斥锁，或者是CAS？

2、为什么要使用defer？

---

这里我们先就第一个问题来解答，为什么要用`atomic.LoadUint32`。

首先我们要了解`atomic.LoadUint32`是什么。它是一个原子操作，基于汇编执行的，颗粒度小，而互斥锁的颗粒度其实是比较大的。

而`CAS`其实是`atomic.CompareAndSwapUint32`，意思就是`Compare And Swap`，把判断和赋值包装成一个原子操作。

那么可不可以这样实现：

```go
if atomic.CompareAndSwapUint32(&o.done, 0, 1) {
    f()
}
```

看上去似乎可行，也只会执行一次，当`o.done==0`时，会赋值为1，然后执行`f()`。

其他并发请求时，会发现`o.done=1`，就不会执行`f()`。

*其实这样是不行的。*

当`o.done`判断为0时，立即设置为1，然后再执行`f()`，这样语义就不正确了。

因为`Once`不仅仅要求只执行一次，还要保证其他在执行这个函数的时候看到`o.done==1`的时候，`f()`已经完成了。

这就涉及到逻辑的正确性。

例如通过`sync.Once`来读取配置，如果调用`sync.Once`通知用户已经读取完成了，而实际上`f()`还在执行，那么这个逻辑其实是错误的。

那么`sync.Once`是如何解决这个问题的？

1、快路径：原子读取`o.done`的值，保证竞态条件正确

2、慢路径：用互斥锁来执行`f()`，执行完成后修改`o.done`

第一次可能在执行互斥锁的时候比较慢，但只要成功执行后，就不会走到互斥锁了，只会走到原子操作。

>  既然内部是使用互斥锁来保证代码的临界区，那么就不能嵌套锁

例如如下使用：

```go
one.Do(func() {
		one.Do(func() {
			// do something
		})
	})
```



---

第二个问题比较简单，如果在执行`f()`发生panic，使用`defer`会保证`o.done`的正确性。



**总结**

1、`Once`对外提供`f()`只执行一次的语义

2、`Once.Do`返回后，`f()`只会被执行一次，如果没有执行完，会阻塞直到执行完毕

3、内部用互斥锁来保证逻辑的原子性，先执行 `f()` ，然后设置 `o.done `标识位

4、`f()`中不能有锁，内部有锁嵌套可能会导致死锁

