# 并发编程之sync.Once


Go语言标准库中的`sync.Once`可以保证go程序在运行期间的某段代码只执行一次。

而我们来看看`sync.Once`的源码，发现是比较少的。

去掉注释后：

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

提出两个问题：

### 为什么`Once.Do`没有用`cas`来判断？

#### 什么是`cas`？

在`sync.atomic`里有`CompareAndSwapUint32`函数来实现`cas`功能。意思就是Compare And Swap的缩写，把判断和赋值包装成一个原子操作。

那么这里为什么用以下方式实现：

```go
if atomic.CompareAndSwapUint32(&o.done,0,1) {
   f()
}
```

看上去，也实现了只执行一次的语义。当`o.done==0`的时候，会赋值`o.done==1`,然后执行`f()`。
其他并发请求的时候，`o.done==1`，就不会再进入这个分支，貌似可行。

注释里有写道：

当`o.done`判断为0时，立即设置成1，然后再执行`f()`，这样语义就不正确。

`Once`需要不仅要保证只执行一次，还要保证其他用户看到`o.done==1`的时候，`f()`已经完成。

这涉及到逻辑的正确性。例如通过`sync.Once`创建唯一的全局变量，如果调用`sync.Once`通知用户已经创建成功，实际上`f()`还在执行过程中，全局变量还没有创建完成，那么这个逻辑就是错误的。

那么怎么解决：

1、快路径：用原子读`o.done`的值，保证竞态条件正确

2、慢路径：既然不能用`cas`原子操作，那么就用锁机制来保证原子性。先执行`f()`，然后再去设置`o.done`为1.

第一次可能在锁互斥的时候比较慢，但只要执行过一次后，就不会走到锁机制，都是走原子操作。

既然内部是用互斥锁来保证代码的临界区，那么就不能嵌套锁

```go
once1.Do(func() {
   once1.Do(func() {
      /* do something*/
    })
})
```

### 为什么`Once.doSlow`用`defer`来加计数？

为什么不可以这样？
```go
if o.done == 0 {
      // todo：为什么用defer来计数？
      f()
      atomic.StoreUint32(&o.done, 1)
   }
```

因为这样处理不了**panic**异常，会导致`o.done`没有加计数，但`f()`已经执行了

### Once的语义

1、`Once.Do`保证只调用一次的语义，无论`f()`内部有没有执行完（`panic`）

2、只有`f()`执行完成，`Once.Do`才会返回，否则阻塞等待`f()`的第一次执行完成。

![抢锁简要演示](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/16/640.png)

![常规操作](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/16/641.png)

### 总结

1、Once 对外提供 f() 只调用一次的语义;

2、Once.Do 返回之后，按照约定，f() 一定被执行过一次，并且只执行过一次。如果没有执行完，会阻塞等待 f() 的第一次执行完成；

3、Once 只执行一次的语义是跟实例绑定的关系，多个 Once 实例的话，每个实例都有一次的机会；

4、内部用锁机制来保证逻辑的原子性，先执行 f() ，然后设置 o.done 标识位；

5、Once 用 defer 机制保证 panic 的场景，也能够保证 o.done 标识位被设置；

6、Once 实例千万注意，不要嵌套，内部有锁，乱用的话容易死锁；
