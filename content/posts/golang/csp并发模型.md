---
title: "CSP并发模型"
date: 2022-03-07T11:14:26+08:00
draft: false

tags: ['golang','csp并发模型']
categories: ["月霜天的小随笔"]
comment: true
toc: true
autoCollapseToc: false
---

## 一、goroutine

- 进程：可并发执行的程序在某个数据集合上的一次计算活动，也是操作系统进行资源分配和调度的基本单位。每个进程都有自己的独立空间，不同进程通过进程间通信来通信。
- 线程：从属于进程，是程序的实际执行者，一个进程可以有多个线程，每个线程会共享父进程的资源。
- 协程：用户态的轻量级线程，协程的调度完全由用户控制。

很明显，在并发编程中，为每个任务创建一个线程会消耗大量的资源，如高内存占用，高cpu调度。

在Go中，使用goroutine让一组可复用的函数运行在一组线程上，即使协程阻塞，该线程的其他协程也会被`runtime`调度。goroutine非常轻量，一个goroutine只占用几KB，这就能运行大量的goroutine，支持高并发。

## 二、GPM模型

在Go中，设计了GPM模型

- G：goroutine协程
- P：processor处理器
- M：thread线程

![gpm模型](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/20/gpm_goroutine2.png)

1、`全局队列`（Global queue）：全局存放等待运行的G

2、`P的本地队列`：存放等待运行的G，不超过256。新建G时，G优先加入本地队列，如果队列满了，把本地队列中的一半移动到`全局队列`中

3、`P列表`：所有的P都在程序启动时创建，并保存在数组中，最多有`GOMAXPROCS`个

4、`M`：线程运行任务需要获取P，从P的本地队列中获取G，P队列为空时，会尝试从全局队列中拿一批G放到P的本地队列，或从其他P的本地队列**偷**一半放到自己的本地队列。

goroutine调度器和OS调度器通过M结合起来，每一个M代表一个内核线程，OS调度器负责把内核线程放到CPU上执行。

### 2.1、P和M的数量

#### 1、P的数量

启动时由环境变量`GOMAXPROCS`或者通过`runtime.GOMAXPROCS()`确定。这就代表程序执行时最多有`GOMAXPROCS`个goroutine在同时运行。

#### 2、M的数量

- go本身限制：程序启动时，会设置M的最大数量，默认是10000。`sched.maxmcount = 10000`

- runtime/debug包中`SetMaxThreads`函数可以设置M的最大数量

- 一个M阻塞了，会创建新的M

#### 3、P数量和M数量的关系

P与M的没有数量关系，一个M阻塞了，P就会去创建或切换另一个M，所以即使P=1，也有可能创建多个M

### 2.2、何时创建P和M

#### 1、P何时创建

在确定P的最大数量后，运行时程序会根据数量创建P

#### 2、M何时创建

没有足够的M来关联P并运行G。比如所有的M都被阻塞了，而P中有很多就绪任务，就会去寻找空闲的M，如果没有空闲的，就会去新建M

### 2.3、调度器设计策略

#### 1、复用线程

避免频繁的创建、销毁线程

- work stealing机制

当线程M没有可以执行的G时，尝试从其他线程绑定的P中偷取G，而不是销毁线程

- hand off机制

当线程M因为G进行系统调用阻塞时，线程M释放绑定的P，把P移交给其他空闲的线程执行

#### 2、抢占

一个goroutine最多占用cpu 10ms，防止其他goroutine被饿死

### 2.4、go func() 调度过程

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/20/gpm_gofunc.png)

1、通过go func()创建一个goroutine

2、新创建的G会先保存在P的本地队列，如果P的本地队列满了，就会存放在全局队列中

3、G只能在M中运行，一个M只能有一个P。M会从P的本地队列读取一个可执行的G来执行，如果本地队列为空，就会想其他的MP中偷取一个可执行的G来执行。

4、一个M调度G的过程是循环过程

5、当M执行某个G发生syscall或其他阻塞操作，M会阻塞，如果当前有一些G在执行，runtime会把这个线程M从P中摘除(detach)，然后再创建一个新的线程

6、当M系统调用结束，这个G会尝试获取一个空闲的P执行，并放入到这个P的本地队列。如果获取不到P，那么这个线程M就会进入休眠状态，加入到空闲线程中，这个G会被放入全局队列中。

> M0：程序启动后的编号为0的主线程，这个M对应的实例会在全局变量runtime.m0中，不需要在堆中分配，M0负责执行初始化操作和启动第一个G，在之后就和其他M一样
>
> G0：启动每个M都会创建的第一个goroutine，G0仅用于负责调度的G，G0不指向任何可执行的函数。每个M都有自己的G0。在调度或系统调用时会使用G0的栈空间, 全局变量的G0是M0的G0。

## 三、调度机制

- Go0.x：基于单线程的调度
- Go1.0：基于多线程的调度
- Go1.1：基于任务窃取的调度
- Go1.2-Go1.13：基于协作的抢占式调度
- Go1.14：基于信号的抢占式调度

### 3.1、基于协作的抢占式调度

goroutine有个字段`stackguard0`，当该字段被设置成`StackPreempt`，意味着当前goroutine发出了抢占请求，同时触发调度器抢占让出线程。

- 编译器会在调用函数前插入`runtime.morestack`，可能会调用`runtime.newstack`进行抢占
- Go语言运行时会在垃圾回收暂停、系统监控发现goroutine运行超过10ms发出抢占请求
- 当发生函数调用时，调用`runtime.newstack`检查goroutine的`stackguard0`字段
- 如果`stackguard0`是`StackPreempt`，触发抢占让出线程

### 3.2、基于信号的抢占式调度

- Go程序启动时，会在runtime.sighandler方法注册并绑定SIGURG信号

```go
func mstartm0() {
	initsig(false)
}

func initsig(preinit bool) {
	for i := uint32(0); i < _NSIG; i++ {
		...
		setsig(i, funcPC(sighandler))
	}
}
```

- 绑定相应的runtime.doSigPreempt抢占方法

```go
func sighandler(sig uint32, info *siginfo, ctxt unsafe.Pointer, gp *g) {
	...
	if sig == sigPreempt {
		doSigPreempt(gp, c)
	}
}
```

- 同时在调度的系统监控runtime.sysmon调用retake方法处理：
  - 抢占阻塞在系统调用的P
  - 抢占运行时间过长的G

- 当符合条件时，会发送信号给M。M收到信号将会睡眠正在阻塞的G，调用绑定信号方法，并重新调度。

### 3.3、为什么要抢占P

```go
package main

import (
	"fmt"
	"runtime"
)

func main() {
	runtime.GOMAXPROCS(1)

	// 协程1
	go func() {
		for  {}
	}()
	// 协程2
	go func() {
		fmt.Println("hello world")
	}()

	select {
	}
}
```

- 在Go1.13版本，是没有输出的。

- 在Go1.14版本，是能打印"hello world"的。

因为不抢占会被一直挂起(hang)。

### 3.4、如何抢占

在`runtime.retake`方法，处理一下两种场景：

- 抢占阻塞在系统调用上的P
- 抢占运行时间过长的G

```go
func retake(now int64) uint32 {
	n := 0
	lock(&allpLock)
	for i := 0; i < len(allp); i++ {
		_p_ := allp[i]
		if _p_ == nil {
			continue
		}
		pd := &_p_.sysmontick
		s := _p_.status
		sysretake := false
	}
	unlock(&allpLock)
	return uint32(n)
}
```

首先会对`allpLock`加锁，可以防止发生变更。

然后对所有的P开始循环处理。

#### 场景1

```go
t := int64(_p_.syscalltick)
if !sysretake && int64(pd.syscalltick) != t {
	pd.syscalltick = uint32(t)
	pd.syscallwhen = now
	continue
}
```

如果在系统调用中超过sysmon ticj周期（至少20us），则会从系统调用中抢占P

#### 场景2

```go
if runqempty(_p_) && atomic.Load(&sched.nmspinning)+atomic.Load(&sched.npidle) > 0 && pd.syscallwhen+10*1000*1000 > now {
   continue
}
```

- `runqempty(_p_)`判断p的任务队列是否为空，以此来检测有没有其他任务需要执行。
- `atomic.Load(&sched.nmspinning)+atomic.Load(&sched.npidle) > 0`判断是否存在空闲的P和正在进行调度窃取的P
- `pd.syscallwhen+10*1000*1000 > now`会判断系统调用是否超过了10ms

完成条件判断后，就进入了抢占步骤

```go
unlock(&allpLock)
incidlelocked(-1)
if atomic.Cas(&_p_.status, s, _Pidle) {
   n++
   _p_.syscalltick++
   handoffp(_p_)
}
incidlelocked(1)
lock(&allpLock)
```

- 解锁
- 减少闲置 M：需要在原子操作（CAS）之前减少闲置 M 的数量（假设有一个正在运行）。否则在发生抢夺 M 时可能会退出系统调用，递增 nmidle 并报告死锁事件。
- 修改P的状态为idle，以便交给其他M使用
- 抢占P和调度M：调用`handoffp`方法从系统调用或锁定的M中强占P，会由新的M接管这个P

## 四、实例

1、P上存在G1，M1获取P后执行G1，G1使用`go func()`创建了G2，G2会优先加入到P的本地队列

2、G1运行完后，M上运行的goroutine切换为G0，G0赋值调度协程的切换。从P的本地队列取G2，从G0切换到G2，开始运行G2。

3、假设P的本地队列能存储4个G，G2要创建6个G，前4个G（G3，G4，G5，G6）已经加入到P的本地队列中，P的本地队列满了

4、G2在创建G7时，发现本地队列满了，会把本地队列的前一半的G（G3，G4），还有新创建的G转移到全局队列

5、G2在创建G8时，P的本地队列没有满，会加入到本地队列中

6、M2绑定的P2的本地队列为空，会去从全局队列中拿一批G放到P2的本地队列。取的个数为

`n=min(len(global queue))/GOMAXPROCS+1,cap(local queue)/2`

7、加入G2一直在M1上运行，而M2运行完本地队列和全局队列的G，就会从M1的P中偷取一半的G放到自己的本地队列中执行

8、此时M1正在运行G2，M2正在运行G8。G8创建了G9后，发生了阻塞的系统调用，M2和P2会发生解绑，P2会执行如下判断：如果P2本地队列有G，全局队列有G或有空闲的M，P2都会唤醒一个M和它绑定，否则P2会加入到空闲P列表，等待M来获取可用的G

9、假如G8创建了G9，发生了非阻塞系统调用，M2和P2会解绑，但M2会记住P2，然后G8和M2进入系统调用状态，当G8和M2退出系统调用时，会尝试获取P2，如果无法获取，则获取空闲的P，如果没有，G8被标记为可运行状态，加入到全局队列，M2因没有P的绑定进入休眠状态。

## 五、总结

Go调度本质是把大量的goroutine分配到少量线程上去执行，并利用多核并行，实现更强大的并发。
