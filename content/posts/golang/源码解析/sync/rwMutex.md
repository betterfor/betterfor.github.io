---
title: "sync之RWMutex"
date: 2021-07-16T10:53:02+08:00
draft: false

tags: ['analysis','sync']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

在go中，每次读写时都需要加互斥锁，这个对程序的影响还是比较大的。所以我们在`sync`包中能够找到另外一个锁---读写锁。当然，读写锁适用于读次数远远多于写次数的场景。

那么读写锁和互斥锁有什么联系和不同呢？

## 一、数据结构

```go
type RWMutex struct {
	w Mutex
	writerSem uint32 
	readerSem uint32 
	readerCount int32 
	readerWait int32 
}
```

可以看到`w`是互斥锁，`writerSem`和`readerSem`都是等待者，`readerCount`是读计数器，`readerWait`是获取写锁需要等待的读锁释放数量。

而最多支持`rwmutexMaxReaders`（2^30^个读计数器）

## 二、整体流程

这里读写锁做了个很精妙的方法区分读写锁，如果有写锁进来，将`readerCount`-`wmutexMaxReaders`，因为`readerCount`最大数量是小于`wmutexMaxReaders`，所以在加锁结果过程中，如果发现`readerCount`<0，那么就知道有写锁加进来了。

### 1、读加锁

每次goroutine获取读锁时，`readerCount`+1，然后分两种情况：

- 如果写锁已经被获取，那么`readerCount`在区间[-`rwmutexMaxReaders`，0），此时挂起读锁的goroutine
- 如果写锁没有被获取，那么`readerCount`>=0，直接获取。

```go
func (rw *RWMutex) RLock() {
	if atomic.AddInt32(&rw.readerCount, 1) < 0 {
		// 将goroutine排到队列尾部，挂起goroutine，监听readerSem信号量
		runtime_SemacquireMutex(&rw.readerSem, false, 0)
	}
}
```

### 2、读解锁

读解锁只会撤销对应的`RLock`调用，不会影响其他读锁

将`readerCount`-1，此时分为以下几种情况：

- 有读锁，没有写锁被挂起，r = `readerCount`-1>=0
- 有读锁，有写锁被挂起，r < 0
- 没有读锁，没有写锁被挂起，r=-1
- 没有读锁，有写锁被挂起，r=-(1<<30)-1<0

如果r>0，那么直接解锁，而对于r<0的情况，第三种和第四种是异常情况，不能用`RUnlock`解写锁，只能将`readerCount`-1，并唤醒等待的读锁，只有将所有读锁的goroutine全部释放，才会唤醒写锁。

```go
func (rw *RWMutex) RUnlock() {
	if r := atomic.AddInt32(&rw.readerCount, -1); r < 0 {
		// Outlined slow-path to allow the fast-path to be inlined
		rw.rUnlockSlow(r)
	}
}

func (rw *RWMutex) rUnlockSlow(r int32) {
	if r+1 == 0 || r+1 == -rwmutexMaxReaders {
		throw("sync: RUnlock of unlocked RWMutex")
	}
	if atomic.AddInt32(&rw.readerWait, -1) == 0 {
		runtime_Semrelease(&rw.writerSem, false, 1)
	}
}
```

### 3、写加锁

写操作是互斥的，所以写操作是需要添加互斥锁，然后通知其他读锁，如果有读锁，就挂起写锁

```go
func (rw *RWMutex) Lock() {
	rw.w.Lock()
	r := atomic.AddInt32(&rw.readerCount, -rwmutexMaxReaders) + rwmutexMaxReaders
	if r != 0 && atomic.AddInt32(&rw.readerWait, r) != 0 {
		runtime_SemacquireMutex(&rw.writerSem, false, 0)
	}
}
```

### 4、写解锁

同样，写解锁向读锁发出通知，还原加锁的`readerCount`

```go
func (rw *RWMutex) Unlock() {
	r := atomic.AddInt32(&rw.readerCount, rwmutexMaxReaders)
	if r >= rwmutexMaxReaders {
		throw("sync: Unlock of unlocked RWMutex")
	}
	for i := 0; i < int(r); i++ {
		runtime_Semrelease(&rw.readerSem, false, 0)
	}
	rw.w.Unlock()
}
```

## 三、nocopy

因为是需要加锁解锁操作，所以在goroutine中是不能使用拷贝的。注释中也明确指定了这一点：


> A RWMutex must not be copied after first use.

如果我们在代码中使用会出现异常情况。

如果结构体对象包含指针字段，当该对象被拷贝时，会使得两个对象中的指针字段变得不再安全。

例如：

```go
type S struct {
	f1 int
	f2 *s
}

type s struct {
	name string
}

func main() {
	mOld := S{
		f1: 0,
		f2: &s{name: "mike"},
	}
	mNew := mOld //拷贝
	mNew.f1 = 1
	mNew.f2.name = "jane"

	fmt.Println(mOld.f1, mOld.f2) //输出：0 &{jane}
}
```

这时修改`mNew`的字段值会把`mOld`字段值修改掉，这就可能会引发安全问题。

### 1、copy检查

```go
func main() {
	var a strings.Builder
	a.Write([]byte("a"))
	b := a
	b.Write([]byte("b"))
}
```

这段代码运行会报错

```text
panic: strings: illegal use of non-zero Builder copied by value
```

这时因为它在内部实现了copyCheck方法

```go
// Do not copy a non-zero Builder.
type Builder struct {
	addr *Builder // of receiver, to detect copies by value
	buf  []byte
}

func (b *Builder) Write(p []byte) (int, error) {
	b.copyCheck()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *Builder) copyCheck() {
	if b.addr == nil {
		b.addr = (*Builder)(noescape(unsafe.Pointer(b)))
	} else if b.addr != b {
		panic("strings: illegal use of non-zero Builder copied by value")
	}
}
```

实现了逻辑也比较简单，`b.addr`指向了自身的指针，如果将`a`赋值给`b`，那么`a`和`b`本身是不同的对象，因此`b.addr`实际会指向`a`导致panic。

>  这里的[noescape](https://www.toutiao.com/i7041097506419245601/)里面就有关于逃逸分析的内容

### 2、nocopy

那有没有更简单的方式呢？有，就是互斥锁的接口

```go
type noCopy struct{}
func (*noCopy) Lock()   {}
func (*noCopy) Unlock() {}
```

`sync`包中都存在nocopy检查，通过`go vet`进行copy检查，都是添加这种类型。

也就是说，我们在代码中也使用这种方式，可以进行nocopy检查。

## 四、总结

- 读锁不能阻塞读锁，所以会添加`readerCount`
- 读锁能够阻塞写锁，直到所有的读锁释放，所以引入`writerSem`
- 写锁要能够阻塞读锁，直到所有写锁释放，所以引入`readerSem`
- 写锁需要能够阻塞写锁，所以使用互斥锁
- 可以通过`Lock`和`Unlock`方式，实现nocopy