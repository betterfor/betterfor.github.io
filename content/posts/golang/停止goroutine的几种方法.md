---
title: "停止goroutine的几种方法"
date: 2021-07-27T09:35:42+08:00
draft: false

tags: ['goroutine', 'golang']
categories: ["note"]
comment: true
toc: true
autoCollapseToc: false
---

在日常工作中，我们经常会用关键字go起一个goroutine。

但是在跑一段时间后，可能会遇到一些问题：当goroutine内的任务运行的太久，内存泄露，或一直阻塞，变成goroutine泄露等一些问题。

那么如何停止goroutine，就需要我们来了解了。

通常会有三种方法：

- 信号量
- context
- 信号量+context

## 信号量

1、借助于channel的close方法关闭通道来关闭协程

```go
func main() {
	ch := make(chan int, 1)
	go func() {
		for  {
			v,ok := <- ch
			if !ok {
				fmt.Println("结束goroutine")
				return
			}
			fmt.Println(v)
		}
	}()

	ch <- 1
	ch <- 2
	close(ch)
	time.Sleep(time.Second)
}
```

当然，也可以使用`for range`的特性

```go
go func() {
	for v := range ch {
		fmt.Println(v)
	}
}()
```

2、使用信号量进行通知

```go
func main() {
	ch := make(chan int, 1)
	done := make(chan struct{})
	go func() {
		for  {
			select {
			case <-ch:
			case <-done:
				close(ch)
				fmt.Println("关闭channel")
				return
			}
		}
	}()

	ch <- 1
	ch <- 2
	done <- struct{}{}
	time.Sleep(time.Second)
}
```

在上述代码中，声明变量`done`，类型是`channel`，作为信号量处理goroutine的关闭。

利用`for-loop`结合`select`关键字来监听，处理相关的逻辑后，再调用`close`来真正关闭channel。

## context

可以借助上下文`Context`来做goroutine的控制和关闭。

```go
func main() {
	ch := make(chan int, 1)
	ctx,cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	go func() {
		for  {
			select {
			case <-ch:
			case <-ctx.Done():
				close(ch)
				fmt.Println("关闭channel")
				return
			}
		}
	}()

	ch <- 1
	ch <- 2
	time.Sleep(time.Second * 2)
}
```

在context中，使用`ctx.Done`获取一个只读的channel，标识当前的channel是否关闭，可能是到期，也可能是被取消。

## 关闭其他goroutine

**我想在 goroutineA 里去停止 goroutineB，有办法吗？**

答案是不能，因为在 Go 语言中，goroutine 只能自己主动退出，一般通过 channel 来控制，不能被外界的其他 goroutine 关闭或干掉，也没有 goroutine 句柄的显式概念。

[question: is it possible to a goroutine immediately stop another goroutine? ](https://github.com/golang/go/issues/32610)

在 Go issues 中也有人提过类似问题，Dave Cheney 给出了一些思考：

- 如果一个 goroutine 被强行停止了，它所拥有的资源会发生什么？堆栈被解开了吗？defer 是否被执行？

- - 如果执行 defer，该 goroutine 可能可以继续无限期地生存下去。
  - 如果不执行 defer，该 goroutine 原本的应用程序系统设计逻辑将会被破坏，这肯定不合理。

- 如果允许强制停止 goroutine，是要释放所有东西，还是直接把它从调度器中踢出去，你想通过此解决什么问题？

这都是值得深思的，另外一旦放开这种限制。作为程序员，你维护代码。很有可能就不知道 goroutine 的句柄被传到了哪里，又是在何时何地被人莫名其妙关闭，非常糟糕...

## 其他方法

- main函数退出，goroutine也会退出
- `runtime.Goexit()`方法可以使goroutine退出

## 总结

goroutine 的设计就是这样的，包括像 goroutine+panic+recover 的设计也是遵循这个原理，因此也有的 Go 开发者总是会误以为跨 goroutine 能有 recover 接住...

记住，在 Go 语言中**每一个 goroutine 都需要自己承担自己的任何责任**，这是基本原则。